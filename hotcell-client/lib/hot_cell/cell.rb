# frozen_string_literal: true

module HotCell
  # One registered cell: where its sockets are, how long this application will wait, and which of its own
  # exception classes to raise for each side of the terminal split.
  #
  # Both socket paths are derived from one directory, so the volume mounts are mechanical rather than
  # something to remember and the two sockets cannot end up apart.
  class Cell
    attr_reader :name, :timeout, :permanent, :transient, :transport

    def initialize(name, dir: nil, timeout: 30, permanent: PermanentFailure, transient: TransientFailure,
                   on_contract_skew: nil, transport: Transport::Socket.new)
      @name = name.to_s
      @dir = dir
      @timeout = timeout
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
      failure.terminal? ? permanent : transient
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
    # converter is restarting is worse than one that serves placeholders. So this warns and carries on.
    def describe
      return nil unless enabled?

      response = control(DESCRIBE)
      unless response.ok?
        HotCell.logger.warn "hotcell #{name}: could not describe the cell (#{response.failure})"
        return nil
      end

      warn_about_timeout response.result
      warn_about_missing_operations response.result
      response.result
    end

    def metrics
      enabled? ? control(METRICS) : nil
    end

    private
      def control(op)
        transport.call self, Request.new(op: op).to_line, [], socket: control_socket
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

        HotCell.logger.warn "hotcell #{name}: this client waits #{timeout}s and the cell says it may take " \
                            "#{needed}s to answer (queue_wait #{described[:queue_wait]} + deadline " \
                            "#{described[:deadline]} + the time to kill and reply), so a saturated cell will " \
                            "arrive here as a transport failure rather than as its own verdict. Deliberate " \
                            "on a synchronous path; a mistake for a background job."
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
