# frozen_string_literal: true

require "fileutils"

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
          Dir.glob("#{TEMPLATES}/**/*.tt").sort
        end

        def install(template, destination, label, out)
          if File.exist?(destination)
            out.puts "   skip  #{label} (already exists)"
          else
            FileUtils.mkdir_p File.dirname(destination)
            FileUtils.cp template, destination
            out.puts " create  #{label}"
          end
        end
    end
  end
end
