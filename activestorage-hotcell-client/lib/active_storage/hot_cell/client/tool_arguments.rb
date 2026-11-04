# frozen_string_literal: true

require "shellwords"
require "active_storage"
require "active_support/core_ext/module/attribute_accessors"

module ActiveStorage
  # The two settings rails/rails#58461 adds, defined here when the installed Active Storage predates them so
  # that an application configures the same thing either way. Rails' own definition takes precedence when it
  # exists — a second mattr_accessor would reset the value the engine already copied from config.
  #
  # Both are shell strings, the shape Rails chose for `video_preview_arguments`, and default to nothing.
  mattr_accessor :ffprobe_arguments, default: "" unless respond_to?(:ffprobe_arguments)
  mattr_accessor :video_preview_input_arguments, default: "" unless respond_to?(:video_preview_input_arguments)

  module HotCell
    module Client
      # Turns one of those shell strings into the argv the cell splices in, split the way Rails splits it —
      # here, in the application, so a malformed string raises against the configuration rather than arriving
      # in the cell as a failed conversion that reads like the document's fault.
      #
      # An empty setting yields nothing at all, so the request carries no key and the operation runs its
      # default argv unchanged.
      module ToolArguments
        def self.split(setting)
          Shellwords.split(setting.to_s)
        end

        def self.payload(key, setting)
          arguments = split(setting)
          arguments.empty? ? {} : { key => arguments }
        end

        # The default of `config.active_storage.ffmpeg_allowed_formats` in Rails and in the cell.
        FFMPEG_ALLOWED_FORMATS = %w[ mov matroska avi mpeg mpegts flv asf ogg mp3 wav flac aac aiff caf ].freeze

        # `config.active_storage.ffmpeg_allowed_formats` as the cell's `formats:`, and `nil` when the
        # application lifted the list. Omitted when Rails would join it into the same whitelist as the cell's
        # default, in any spelling, because a cell that predates `formats:` answers `failed` to it, so an
        # application that leaves the setting alone can upgrade before its cells do.
        def self.formats_payload
          setting = ActiveStorage.ffmpeg_allowed_formats
          formats = Array(setting).map(&:to_s) unless setting.nil?
          formats&.join(",") == FFMPEG_ALLOWED_FORMATS.join(",") ? {} : { formats: formats }
        end
      end
    end
  end

  # rails/rails@29468ed adds this setting too, defined here on the same terms as the two above.
  mattr_accessor :ffmpeg_allowed_formats, default: HotCell::Client::ToolArguments::FFMPEG_ALLOWED_FORMATS \
    unless respond_to?(:ffmpeg_allowed_formats)
end
