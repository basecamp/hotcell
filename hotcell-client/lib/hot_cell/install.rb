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
          install template, File.join(root, "hotcell", relative), "hotcell/#{relative}", out
        end
      end

      private
        def templates
          Dir.glob("#{TEMPLATES}/**/*.tt", File::FNM_DOTMATCH).sort
        end

        def install(template, destination, label, out)
          if File.exist?(destination)
            out.puts "   skip  #{label} (already exists)"
          else
            FileUtils.mkdir_p File.dirname(destination)
            File.write destination, render(template)
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
