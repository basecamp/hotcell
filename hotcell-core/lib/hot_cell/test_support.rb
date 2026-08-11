# frozen_string_literal: true

require "tempfile"

module HotCell
  # Fixtures and waits for the suites of all three gems, shipped rather than copied.
  #
  # Same reasoning as `hot_cell/test_cell.rb` shipping from hotcell-server: a helper every consumer needs is
  # one every consumer should get, not one each writes again. Before this, `with_file` had three
  # byte-identical copies, `wait_until` had two — one of them inside a test file rather than a helper — and
  # the monotonic clock was hand-rolled six times in code that already loads HotCell::Clock.
  #
  # It lives in hotcell-core because that is the gem all three load. Requiring it is opt-in, so nothing here
  # reaches a production graph unless a suite asks for it.
  #
  # Include into a Minitest::Test subclass; `skip` and `flunk` are called on the including test.
  module TestSupport
    private
      # Descriptors have to be regular files, so every fixture is a real file on disk.
      def with_file(contents = "")
        Tempfile.create([ "hotcell", ".bin" ], binmode: true) do |file|
          file.write contents
          file.flush
          yield file.path
        end
      end

      # A source and a destination, which is the shape of most requests.
      def with_files(contents = "source bytes")
        with_file(contents) { |source| with_file { |destination| yield source, destination } }
      end

      def reading(path, &block)
        File.open path, "rb", &block
      end

      def writing(path, &block)
        File.open path, "wb", &block
      end

      def updating(path, &block)
        File.open path, "r+b", &block
      end

      def open_descriptors
        skip "counting open descriptors needs Linux" unless File.directory?("/proc/self/fd")

        Dir.children("/proc/self/fd").size
      end

      # True while the process exists and is not a zombie. A killed process lingers as a zombie until its
      # parent reaps it, and a zombie is dead for a caller watching for a sweep. The state is the first
      # token after the final `)` of /proc/<pid>/stat, which is where the comm field ends.
      def process_running?(pid)
        state = File.read("/proc/#{pid}/stat")[/\)\s+(\S)/, 1]
        !state.nil? && state != "Z"
      rescue Errno::ENOENT
        false
      end

      # A cell writes its log and removes its scratch after it has answered, so a few properties are
      # genuinely asynchronous with respect to the caller. Bounded polling says so; a sleep would not.
      def wait_until(within: 5, what: "the condition")
        deadline = Clock.now + within

        until yield
          flunk "#{what} did not happen within #{within}s" if Clock.now > deadline

          sleep 0.01
        end
      end

      def elapsed
        at = Clock.now
        yield
        Clock.now - at
      end
  end
end
