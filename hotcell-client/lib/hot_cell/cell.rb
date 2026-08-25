# frozen_string_literal: true

module HotCell
  # One registered cell: where its sockets are, how long this application will wait, and which of its own
  # exception classes to raise for each side of the permanent split.
  #
  # Both socket paths are derived from one directory, so the volume mounts are mechanical rather than
  # something to remember and the two sockets cannot end up apart.
  class Cell
    attr_reader :name, :timeout, :control_timeout, :permanent, :transient, :transport

    # `timeout` covers work, so it is sized to clear the cell's `answer_within` and a saturated cell reports
    # its own verdict rather than a transport failure. `control_timeout` covers `describe` and `metrics`,
    # which the supervisor answers inline with no fork or queue — so it is short on purpose. Sharing one
    # number would give the call whose job is to say "this cell is down" the patience of a video transcode.
    #
    # Both bound the answer rather than the whole call: connecting is not covered. Transport::Socket says
    # why that is left alone.
    def initialize(name, dir: nil, timeout: 30, control_timeout: 5,
                   permanent: PermanentFailure, transient: TransientFailure,
                   on_contract_skew: nil, transport: Transport::Socket.new)
      @name = name.to_s
      @dir = dir
      @timeout = timeout
      @control_timeout = control_timeout
      @permanent = permanent
      @transient = transient
      @on_contract_skew = on_contract_skew
      @transport = transport

      verify_classification!
    end

    # Resolved on every call rather than at registration, which is what makes turning a path on a
    # configuration change instead of a release. A directory consulted once in HotCell.register would make
    # every flip a deploy, and reverting one too.
    def directory
      return @dir.call if @dir.respond_to?(:call)

      @dir || (HotCell.root && File.join(HotCell.root, name))
    end

    # Unset means this path is off, and the caller runs in process exactly as it did before.
    def enabled?
      !directory.nil?
    end

    def work_socket
      File.join directory, "work.sock"
    end

    def control_socket
      File.join directory, "control.sock"
    end

    def exception_for(failure)
      failure.permanent? ? permanent : transient
    end

    # Contract skew needs its own reporting hook because applications rescue broadly around
    # representations, so "raise" is indistinguishable from "placeholder" and the skew is otherwise
    # invisible. An application running several clients against several independently-booted cells needs to
    # know which one skewed.
    def report_contract_skew(error)
      @on_contract_skew&.call error, self
    end

    # Static, and called once at boot. The cheapest way to catch a client pointed at a cell that does not
    # carry the operation it wants, which is otherwise an `unsupported` on the first real request.
    #
    # Boot must not fail when a cell does not answer. A cell that is down at app boot is a degraded
    # deployment rather than a broken one, and an application that refuses to start because its thumbnail
    # cell is restarting is worse than one that serves placeholders. So this warns and carries on.
    #
    # Nor when a cell answers something this client cannot read. The three warnings below reach into the
    # description without checking types, so a cell that sends the wrong ones raises here — and the README
    # calls `describe_cells` from `after_initialize`, where that is not a failed check but an application
    # that does not boot. The process that wrote the description is the one that runs untrusted content.
    # So rescue: returning nil is what an unreachable cell already returns, and every caller handles it.
    def describe
      return nil unless enabled?

      response = control(DESCRIBE)
      return warn_unreachable(response.failure) unless response.ok?

      response.result.tap do |described|
        warn_about_timeout described
        warn_about_missing_operations described
        warn_about_group_skew described
      end
    rescue StandardError => error
      HotCell.logger.warn "hotcell #{name}: this cell's description could not be read and is being " \
                          "ignored (#{error.class}: #{Failure.one_line error.message}). Boot continues; " \
                          "nothing it carries is assumed."
      nil
    end

    def metrics
      enabled? ? control(METRICS) : nil
    end

    private
      # A cell's sockets are `0660`, so the group that lets a worker re-open a descriptor is also the group
      # that admits a caller. EACCES therefore means one thing, and it is worth saying rather than leaving an
      # operator to read "could not describe the cell" as "the cell is down". Every other failure reads that
      # way correctly, because a restarting accessory is the common one.
      def warn_unreachable(failure)
        HotCell.logger.warn "hotcell #{name}: #{unreachable_because failure}"
        nil
      end

      def unreachable_because(failure)
        if failure.error_class == "Errno::EACCES"
          "this process may not open the cell's socket. Both sides share a group, and this one is in " \
          "#{Process.groups.sort.inspect}. Add the cell's gid to this container (Kamal: `group-add` under " \
          "the role's `options:`)."
        else
          "could not describe the cell (#{Failure.one_line failure})"
        end
      end

      def control(op)
        transport.call self, Request.new(op: op).to_line, [], socket: control_socket, timeout: control_timeout
      end

      # The client's timeout is a sum rather than a comparison: a request may wait queue_wait in the queue
      # and then run for deadline, and only then does the cell get to say what happened.
      #
      # Being bound tighter than that is defensible and it is a choice, not a mistake. A synchronous
      # representation request wants it tighter, because a thread held for sixty seconds is a thread not
      # serving traffic. A background job wants it looser, so it receives `capacity` or `killed` and can act
      # on them rather than guessing from a socket error. Both outcomes are transient, so neither is
      # misclassified — which is the only reason this is safe.
      # The cell states this; adding it up here would mean guessing at stages only the supervisor knows about.
      # A cell too old to report it says nothing, which is the right answer for a number we cannot know.
      def warn_about_timeout(described)
        needed = described[:answer_within]
        return if needed.nil? || timeout.nil? || timeout >= needed

        HotCell.logger.warn "hotcell #{name}: this client waits #{seconds timeout} and the cell says it may " \
                            "take #{seconds needed} to answer, so a saturated cell will arrive here as a " \
                            "transport failure rather than as its own verdict. Deliberate on a synchronous " \
                            "path; a mistake for a background job."
      end

      # The cell reports seconds as floats, and "41.0s" is a worse sentence than "41s".
      def seconds(value)
        "#{format("%g", value)}s"
      end

      # HotCell.group is a number in this application's deploy file, and the cell's gid is baked into an
      # image built somewhere else. Nothing else compares them, so a cell image that changed its gid would
      # be an EACCES on every conversion — with a probe that was green the day before.
      #
      # A cell too old to report its groups says nothing, which is the right answer for a number we cannot
      # know. So is a client with no group configured, which is the one-user case.
      def warn_about_group_skew(described)
        carried = described[:groups]
        return if HotCell.group.nil? || carried.nil? || carried.include?(HotCell.group)

        HotCell.logger.warn "hotcell #{name}: HotCell.group is #{HotCell.group} and this cell runs in " \
                            "#{carried.inspect}, so it cannot open a file this application hands it and " \
                            "every operation that gives a tool a filename will fail with EACCES."
      end

      def warn_about_missing_operations(described)
        carried = Array(described[:operations])
        wanted = HotCell.clients.select { |client| client.hotcell == name }

        wanted.reject { |client| carried.include?(client.operation) }.each do |client|
          HotCell.logger.warn "hotcell #{name}: #{client} wants #{client.operation.inspect} and this cell " \
                              "carries #{carried.inspect}"
        end
      end

      def verify_classification!
        return if permanent.nil? || transient.nil?
        return unless transient <= permanent

        raise ConfigurationError,
              "transient: #{transient} descends from permanent: #{permanent}, so every retryable failure " \
              "would be recorded as a permanent one. The inheritance graph is the classification."
      end
  end
end
