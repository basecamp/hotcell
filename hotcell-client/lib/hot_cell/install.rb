# frozen_string_literal: true

require "erb"
require "fileutils"

require "hot_cell/client/version"

module HotCell
  # Writes the hotcell/ directory into an application: a complete Dockerfile to customize, the cell's
  # Gemfile, and an operations/ directory the cell loads at boot. Everything installs inline rather than
  # deriving from a published base image, so the whole cell is the application's to read and change.
  #
  # A file that already exists is left exactly as it is, so running this again after customizing is safe.
  module Install
    TEMPLATES = File.expand_path("install", __dir__)

    class << self
      def call(root, out: $stdout)
        templates.each do |template|
          relative = template.delete_prefix("#{TEMPLATES}/").delete_suffix(".tt")
          write File.join(root, "hotcell", relative), "hotcell/#{relative}", out do
            render template
          end
        end

        keep_operations root, out
      end

      private
        def templates
          Dir.glob("#{TEMPLATES}/**/*.tt", File::FNM_DOTMATCH).sort
        end

        # **The directory the generated Dockerfile copies, made here rather than shipped.**
        #
        # It used to be a template, `install/operations/.keep.tt`, and a dotfile is exactly what the
        # gemspec's `Dir["lib/**/*"]` does not match — so the published 0.1.0 carried the directory's only
        # file nowhere, `COPY operations/` had nothing to copy, and the advertised scaffold could not build.
        # The checkout's own install test could not see it, because in a checkout the file is simply there.
        #
        # An empty file rather than an empty directory, because the application's git is what has to keep
        # this after a fresh clone, and git tracks no empty directories.
        def keep_operations(root, out)
          write File.join(root, "hotcell", "operations", ".keep"), "hotcell/operations/.keep", out do
            ""
          end
        end

        def write(destination, label, out)
          if File.exist?(destination)
            out.puts "   skip  #{label} (already exists)"
          else
            FileUtils.mkdir_p File.dirname(destination)
            File.write destination, yield
            out.puts " create  #{label}"
          end
        end

        # A .tt is ERB, so a template can name something only the installing gem knows. The Gemfile uses it
        # to pin the cell to this client's version, which is the one number the two sides must agree on.
        def render(template)
          ERB.new(File.read(template), trim_mode: "-").result(binding)
        end
    end
  end
end
