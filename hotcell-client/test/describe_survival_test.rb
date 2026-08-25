# frozen_string_literal: true

require "test_helper"

# `describe` is the one call a cell answers before the application is serving, and the README puts it in
# `after_initialize`, where an exception is not a failed check but a Rails application that does not boot.
# The process answering runs untrusted content, and `docs/DESIGN.md` records the socket theft that lets a
# compromised worker be the thing that answers — so nothing it sends may raise out of `describe`.
class DescribeSurvivalTest < HotCellClientTest
  # Correctly framed responses whose contents this client cannot use. Each raised out of `describe` before
  # the rescue was added.
  UNUSABLE = [
    %({"answer_within":"attacker-controlled"}),
    %({"answer_within":{"not":"a number"}}),
    %(["not","an","object"]),
    %("a string"),
    %(null),
  ].freeze

  # Legitimate, and the reason this is a rescue rather than a required shape: `describe` is additive, so a
  # cell reports what it has and one too old to report a field must stay readable.
  USABLE = [
    %({}),
    %({"answer_within":31}),
    %({"answer_within":1.0,"groups":[],"operations":[]}),
  ].freeze

  def test_nothing_a_cell_answers_raises_out_of_describe
    UNUSABLE.each do |result|
      with_cell_describing(result, timeout: 30) do |cell|
        assert_nil quietly { cell.describe }, "#{result} was believed"
      end
    end
  end

  def test_a_cell_that_reports_fewer_fields_is_still_read
    USABLE.each do |result|
      with_cell_describing(result, timeout: 30) do |cell|
        refute_nil quietly { cell.describe }, "#{result} was discarded"
      end
    end
  end

  # `groups` is only read when this application has a group to compare it against, so a wrong type there
  # raises for a configured application and not for a bare one. What breaks is the code that reads the
  # field, not the shape of the response — which is why this is a rescue and not a check on the way in.
  def test_a_wrong_type_is_ignored_where_the_consumer_reaches_it
    with_cell_describing(%({"groups":5}), timeout: 30) do |cell|
      HotCell.group = 1000

      assert_nil quietly { cell.describe }, "a groups the consumer could not read was believed"
    ensure
      HotCell.group = nil
    end
  end

  def test_an_ignored_description_says_why
    with_cell_describing(%({"answer_within":"attacker-controlled"}), timeout: 30) do |cell|
      warnings = capturing_warnings { cell.describe }

      assert_match "could not be read and is being ignored", warnings
      assert_match "ArgumentError", warnings
    end
  end

  # Everything after the prefix on this line was chosen by the cell. `Failure.sanitize` bounds and scrubs
  # it but leaves newlines alone, so an unescaped message is a second log line that nothing wrote.
  def test_a_cell_cannot_forge_a_log_line
    forged = %(ERROR -- : hotcell test: everything is fine)
    failure = %({"code":"failed","message":"first line\\n#{forged}"})

    with_cell_describing(nil, failure: failure) do |cell|
      warnings = capturing_warnings { cell.describe }

      assert_match "first line", warnings
      assert_equal 1, warnings.lines.grep(/hotcell test/).size, "the cell wrote a line of its own: #{warnings}"
      assert_match '\n', warnings
    end
  end

  def test_one_unusable_cell_does_not_stop_the_others_being_read
    Dir.mktmpdir "hc" do |root|
      answering root, "hostile", %({"answer_within":"attacker-controlled"})
      answering root, "honest", %({"answer_within":1.0,"groups":[],"operations":[]})

      HotCell.root = root
      %w[ hostile honest ].each do |name|
        HotCell.register name, timeout: 30, control_timeout: 2, permanent: Unprocessable,
                               transient: TemporarilyUnavailable
      end

      described = quietly { HotCell.describe_cells }

      assert_nil described["hostile"], "the hostile cell was believed"
      refute_nil described["honest"], "one bad peer stopped the others being read"
    ensure
      stop_answering
    end
  end

  private
    def quietly
      HotCell.logger = Logger.new(File::NULL)
      yield
    end

    def capturing_warnings
      captured = StringIO.new
      HotCell.logger = Logger.new(captured)
      yield
      captured.string
    ensure
      HotCell.logger = Logger.new(File::NULL)
    end

    def with_cell_describing(result, name: "test", failure: nil, **register)
      Dir.mktmpdir "hc" do |root|
        answering root, name, result, failure: failure
        HotCell.root = root

        yield HotCell.register(name, control_timeout: 2, permanent: Unprocessable,
                                     transient: TemporarilyUnavailable, **register)
      ensure
        stop_answering
      end
    end

    # One cell's control socket, answering the same line to whatever connects.
    def answering(root, name, result, failure: nil)
      directory = File.join(root, name)
      Dir.mkdir directory

      listener = UNIXServer.new File.join(directory, "control.sock")
      line = if failure
        %({"v":1,"ok":false,"error":#{failure},"timing":{}}\n)
      else
        %({"v":1,"ok":true,"result":#{result},"timing":{}}\n)
      end

      (@listeners ||= []) << listener
      (@answerers ||= []) << Thread.new do
        loop do
          connection = listener.accept
          connection.readpartial(4096)
          connection.write line
          connection.close
        end
      rescue IOError, Errno::EBADF
        nil
      end
    end

    def stop_answering
      @answerers&.each(&:kill)
      @listeners&.each(&:close)
      @answerers = @listeners = nil
    end
end
