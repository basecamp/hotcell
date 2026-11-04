# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"

# Every ImageMagick process a cell starts runs under the shipped security policy, plus any operator policy
# after it: `identify` and `magick` spawned by mini_magick, and `magickload` inside a worker.
#
# A test that names `ActiveStorage::HotCell::Server::ImageMagick` would set `MAGICK_CONFIGURE_PATH` in this
# process and in every cell forked from it, so each check runs in a cell or a child process, the way a worker
# would.
class MagickPolicyTest < ActiveStorageHotCellTest
  POLICY_DIRECTORY = File.expand_path("../lib/active_storage/hot_cell/server/image_magick", __dir__)

  DENIED_CODERS = %w[ MSL EPHEMERAL TEXT MPC SHOW WIN PLT URL HTTP HTTPS FTP FILE PS PS2 PS3 EPS EPS2 EPS3 EPI
                      EPSF EPSI EPT EPT2 EPT3 PDF AI EPDF PDFA POCKETMOD XPS PCL ].freeze
  GHOSTSCRIPT_MODULES = %w[ PS PS2 PS3 EPT PDF ].freeze

  POSTSCRIPT = "%!PS\nshowpage\n"

  class << self
    attr_accessor :registered_formats, :coder_errors
  end

  def test_every_rule_in_the_shipped_policy_is_loaded
    loaded = in_a_worker(<<~RUBY).split(/^Path: /).find { |section| section.start_with?(POLICY_DIRECTORY) }
      print MiniMagick.identify { |identify| identify.list "policy" }
    RUBY

    refute_nil loaded, "identify did not load #{POLICY_DIRECTORY}"
    assert_equal shipped_rules.size, loaded.scan(/^  Policy: /).size
  end

  def test_the_shipped_policy_denies_the_expected_coders_the_ghostscript_delegate_and_filename_indirection
    assert_equal DENIED_CODERS, shipped_rules.filter_map { |domain, _, pattern| pattern if domain == "coder" }
    assert_equal [ [ "delegate", "none", "gs" ], [ "path", "none", "@*" ] ],
                 shipped_rules.reject { |domain, _, _| domain == "coder" }
    assert_equal [ "none" ], shipped_rules.map { |_, rights, _| rights }.uniq
  end

  def test_every_ghostscript_backed_coder_is_denied_by_name
    ghostscript_backed = registered_formats.filter_map { |token, mod, _| token if GHOSTSCRIPT_MODULES.include?(mod) }

    assert_empty ghostscript_backed - DENIED_CODERS
  end

  DENIED_CODERS.each do |coder|
    define_method "test_the_shipped_policy_denies_the_#{coder}_coder" do
      skip "this ImageMagick has no #{coder} coder" unless registered_coders.include?(coder)

      assert_match(/security policy .#{coder}'/, coder_errors.fetch(coder))
    end
  end

  def test_the_shipped_policy_refuses_filename_indirection
    assert_match(/security policy .@/, coder_errors.fetch("@"))
  end

  # The premise of the cell tests below: without the shipped policy, these files reach their coder. Each one
  # can fail here for want of Ghostscript or a pixel cache, but not because a policy refused it. Debian's own
  # policy refuses PostScript, and on such a host the cell tests prove nothing about it.
  def test_without_the_shipped_policy_the_content_reaches_its_coder
    with_sniffed_inputs do |inputs|
      inputs.each do |coder, path|
        _output, error, _status = Open3.capture3({ "MAGICK_CONFIGURE_PATH" => nil }, *IDENTIFY, path)

        skip "this host's own policy refuses #{coder}" if error.match?(/security policy .#{coder}'/)
        refute_match(/security policy/, error)
      end
    end
  end

  # ImageMagick chooses a coder from the content it is given, so a cell refuses these through the descriptor
  # it is handed, with no prefix to name the coder.
  def test_the_magick_analyzer_refuses_a_denied_coder_chosen_by_content
    with_sniffed_inputs do |inputs|
      Cell.boot do |cell|
        inputs.each do |coder, path|
          failure = assert_failed "unreadable", cell.call("active_storage.analyzers.image.magick", inputs: [ path ])

          assert_match(/security policy .#{coder}'/, failure.message)
        end
      end
    end
  end

  def test_the_magick_transformer_refuses_a_denied_coder_chosen_by_content
    with_sniffed_inputs do |inputs|
      Cell.boot do |cell|
        inputs.each do |coder, path|
          with_output(".png") do |destination|
            failure = assert_failed "unreadable", cell.call("active_storage.transformers.image.magick",
                                                            inputs: [ path ], outputs: [ destination ],
                                                            payload: { format: "png" })

            assert_match(/security policy .#{coder}'/, failure.message)
          end
        end
      end
    end
  end

  def test_every_fixture_still_analyzes_and_transforms_under_the_shipped_policy
    Cell.boot do |cell|
      %w[ colour.png colour.jpg animated.gif colour.bmp rotated.jpg ].each do |name|
        result = assert_ok(cell.call("active_storage.analyzers.image.magick", inputs: [ fixture(name) ])).result
        assert_operator result[:width], :>, 0, name

        with_output(".png") do |destination|
          assert_ok cell.call("active_storage.transformers.image.magick",
                              inputs: [ fixture(name) ], outputs: [ destination ],
                              payload: { format: "png", operations: { resize_to_limit: [ 8, 8 ] } })
        end
      end
    end
  end

  def test_the_shipped_directory_comes_before_the_images_own_and_appears_once
    {
      nil                               => POLICY_DIRECTORY,
      ""                                => POLICY_DIRECTORY,
      "/etc/magick"                     => "#{POLICY_DIRECTORY}:/etc/magick",
      "/etc/magick::/opt/magick"        => "#{POLICY_DIRECTORY}:/etc/magick:/opt/magick",
      "/etc/magick:#{POLICY_DIRECTORY}" => "#{POLICY_DIRECTORY}:/etc/magick",
    }.each do |from_the_image, expected|
      worker_and_magick = JSON.parse in_a_worker(<<~RUBY, "MAGICK_CONFIGURE_PATH" => from_the_image)
        require "json"
        puts JSON.dump([ ENV["MAGICK_CONFIGURE_PATH"], MiniMagick.cli_env["MAGICK_CONFIGURE_PATH"] ])
      RUBY

      assert_equal [ expected, expected ], worker_and_magick, "MAGICK_CONFIGURE_PATH=#{from_the_image.inspect}"
    end
  end

  # ImageMagick would split the directory in two and load neither half.
  def test_loading_from_a_directory_whose_path_has_a_separator_in_it_fails
    Dir.mktmpdir do |directory|
      gems = File.join(directory, "hotcell#{File::PATH_SEPARATOR}gems").tap { |path| Dir.mkdir(path) }
      FileUtils.cp_r File.expand_path("../lib", __dir__), gems
      script = <<~RUBY
        $LOAD_PATH.unshift #{File.join(gems, "lib").inspect}
        require "active_storage/hot_cell/server/image_magick"
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, "-r", "bundler/setup", "-e", script, chdir: directory)

      refute_predicate status, :success?
      assert_match(/HotCell::ConfigurationError/, output)
    end
  end

  # The operator's way to re-allow a coder: a later rule that matches wins.
  def test_a_policy_the_image_names_can_allow_a_coder_the_shipped_policy_denies
    with_operator_policy %(<policy domain="coder" rights="read|write" pattern="TEXT"/>) do |directory|
      refute_match(/security policy/, coder_errors("MAGICK_CONFIGURE_PATH" => directory).fetch("TEXT"))
    end
  end

  # Through a real cell, which inherits the image's environment the way a deployed one does.
  def test_a_policy_the_image_names_reaches_the_cells_magick_operations
    with_operator_policy %(<policy domain="coder" rights="none" pattern="PNG"/>) do |directory|
      with_environment "MAGICK_CONFIGURE_PATH" => directory do
        Cell.boot do |cell|
          failure = assert_failed "unreadable", cell.call("active_storage.analyzers.image.magick",
                                                          inputs: [ fixture("colour.png") ])

          assert_match(/security policy .PNG'/, failure.message)
        end
      end
    end
  end

  # libvips refuses `magickload` on untrusted input, so the shipped operations never reach it. An operation
  # that unblocks it runs ImageMagick in the worker's own process, which reads the worker's environment rather
  # than mini_magick's. A cell may load only the vips operations.
  def test_magickload_in_a_worker_runs_under_the_shipped_policy
    with_sniffed_inputs do |inputs|
      assert_match(/security policy .MPC'/,
                   magickload_error(inputs.fetch("MPC"), "active_storage/hot_cell/server/analyzers/image/vips"))
    end
  end

  # The premise: the same load in a process that never required the operations is not refused by a policy.
  def test_magickload_without_the_operations_is_not_refused_by_a_policy
    with_sniffed_inputs do |inputs|
      refute_match(/security policy/, magickload_error(inputs.fetch("MPC"), "image_processing/vips"))
    end
  end

  private
    def shipped_rules
      File.read(File.join(POLICY_DIRECTORY, "policy.xml"))
        .scan(/<policy domain="(\w+)" rights="([^"]+)" pattern="([^"]+)"/)
    end

    def registered_formats
      self.class.registered_formats ||= IO.popen([ *IDENTIFY, "-list", "format" ], &:read)
        .scan(/^\s*(\w+)\*?\s+(\w+)\s+([rw+-]{3})/)
        .select { |_token, _module, rights| rights.match?(/[rw]/) }
    end

    def registered_coders
      registered_formats.map(&:first)
    end

    # One worker answers for every coder, because a process per coder costs a Ruby boot each.
    def coder_errors(environment = {})
      return self.class.coder_errors ||= coder_errors_in_a_worker({}) if environment.empty?

      coder_errors_in_a_worker(environment)
    end

    def coder_errors_in_a_worker(environment)
      Dir.mktmpdir do |directory|
        commands = coder_commands(directory)

        JSON.parse in_a_worker(<<~RUBY, environment)
          require "json"
          errors = #{commands.inspect}.to_h do |coder, (tool, arguments)|
            MiniMagick.public_send(tool) { |command| arguments.each { |argument| command << argument } }
            [ coder, "" ]
          rescue MiniMagick::Error => error
            [ coder, error.message.dup.force_encoding("UTF-8").scrub ]
          end
          puts JSON.dump(errors)
        RUBY
      end
    end

    # How to reach each coder this ImageMagick has, by name. EPHEMERAL deletes what it reads, so it reads a copy.
    def coder_commands(directory)
      jpeg = fixture("colour.jpg")
      postscript = File.join(directory, "page.ps").tap { |path| File.write(path, POSTSCRIPT) }
      script = File.join(directory, "script.msl").tap do |path|
        File.write(path, %(<image><read filename="#{jpeg}"/></image>))
      end
      ephemeral = File.join(directory, "ephemeral.jpg").tap { |path| FileUtils.cp(jpeg, path) }

      (DENIED_CODERS & registered_coders).to_h do |coder|
        prefix = coder.downcase
        command =
          case coder
          when "MSL" then [ :identify, [ "msl:#{script}" ] ]
          when "PS", "EPS", "EPI", "EPSF", "EPSI", "EPT", "EPT2", "EPT3", "XPS", "PCL"
            [ :identify, [ "#{prefix}:#{postscript}" ] ]
          when "PDF", "AI", "EPDF", "PDFA", "POCKETMOD" then [ :identify, [ "#{prefix}:#{fixture("sample.pdf")}" ] ]
          when "PS2", "PS3", "EPS2", "EPS3"
            [ :convert, [ jpeg, "#{prefix}:#{File.join(directory, "page.#{prefix}")}" ] ]
          when "MPC", "TEXT" then [ :identify, [ "#{prefix}:#{jpeg}" ] ]
          when "EPHEMERAL" then [ :identify, [ "ephemeral:#{ephemeral}" ] ]
          when "FILE" then [ :identify, [ "file://#{jpeg}" ] ]
          when "URL", "HTTP", "HTTPS", "FTP" then [ :identify, [ "#{prefix}://127.0.0.1:1/colour.jpg" ] ]
          when "SHOW", "WIN", "PLT" then [ :convert, [ jpeg, "#{prefix}:" ] ]
          else flunk "no command reaches the #{coder} coder; add one to coder_commands"
          end

        [ coder, command ]
      end.merge("@" => [ :identify, [ "@#{jpeg}" ] ])
    end

    # Files whose content alone chooses a denied coder. MPC is a pixel cache header, which ImageMagick reads
    # without Ghostscript; the cache it names does not exist, so it fails either way and only the message differs.
    def with_sniffed_inputs
      Dir.mktmpdir do |directory|
        inputs = {
          "MPC" => File.join(directory, "cache").tap { |path| File.write(path, "id=MagickCache\ncolumns=1 rows=1\n\f\n:\x1A") },
          "PS"  => File.join(directory, "page").tap { |path| File.write(path, POSTSCRIPT) },
        }

        yield inputs
      end
    end

    def magickload_error(path, library)
      in_a_child(<<~RUBY)
        require #{library.inspect}
        Vips.block_untrusted false
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          Vips::Image.magickload(#{path.inspect}).avg
          writer.write "loaded"
        rescue Vips::Error => error
          writer.write error.message
        ensure
          writer.close
          exit! 0
        end
        writer.close
        print reader.read
        Process.wait pid
      RUBY
    end

    def with_operator_policy(rules)
      Dir.mktmpdir "hotcell-operator-policy" do |directory|
        File.write File.join(directory, "policy.xml"), "<policymap>#{rules}</policymap>"
        yield directory
      end
    end

    # The cell inherits this through the fork, which is how a real one gets its environment too.
    def with_environment(values)
      was = values.to_h { |name, _| [ name, ENV[name] ] }
      values.each { |name, value| ENV[name] = value }
      yield
    ensure
      was.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end

    # What a worker does before it performs: requires the operation in the supervisor, then instantiates it.
    def in_a_worker(script, environment = {})
      in_a_child(<<~RUBY, environment)
        require "active_storage/hot_cell/server/analyzers/image/magick"
        ActiveStorage::HotCell::Server::Analyzers::Image::Magick.new
        #{script}
      RUBY
    end

    # The image may already set `MAGICK_CONFIGURE_PATH`, and a developer's shell may too, so the child starts
    # without one and takes only what the case gives it. It runs in a directory of its own, because a coder this
    # ImageMagick does not deny writes its output into the working directory.
    def in_a_child(script, environment = {})
      environment = { "MAGICK_CONFIGURE_PATH" => nil,
                      "BUNDLE_GEMFILE" => ENV.fetch("BUNDLE_GEMFILE", File.expand_path("../../Gemfile", __dir__)) }
        .merge(environment)
      lib = File.expand_path("../lib", __dir__)

      output, status = Dir.mktmpdir do |directory|
        Open3.capture2(environment, RbConfig.ruby, "-I", lib, "-r", "bundler/setup", "-e", script, chdir: directory)
      end
      assert_predicate status, :success?, "the child failed: #{output}"
      output
    end
end
