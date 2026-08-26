# frozen_string_literal: true

require "active_storage"
require "active_support/core_ext/string/inflections"

require "active_storage/hot_cell/client/version"
require "active_storage/hot_cell/client/operations"
require "active_storage/hot_cell/client/transformers/image/vips"
require "active_storage/hot_cell/client/transformers/image/magick"
require "active_storage/hot_cell/client/analyzers/image/vips"
require "active_storage/hot_cell/client/analyzers/image/magick"
require "active_storage/hot_cell/client/analyzers/video/ffprobe"
require "active_storage/hot_cell/client/analyzers/audio/ffprobe"
require "active_storage/hot_cell/client/previewers/pdf/mutool"
require "active_storage/hot_cell/client/previewers/pdf/poppler"
require "active_storage/hot_cell/client/previewers/video/ffmpeg"
require "active_storage/hot_cell/client/railtie" if defined?(::Rails::Railtie)

module ActiveStorage
  module HotCell
    # Everything the application side defines lives under this, and everything the cell side defines lives under
    # ActiveStorage::HotCell::Server. Not a tidying convention: the two gems are never both loaded in production,
    # and a cell is forked from a process that may well have loaded this one — after which a shared name is a
    # superclass mismatch while the cell boots. Two namespaces make that impossible rather than avoided.
    module Client
      # These four jobs declare `retry_on ActiveStorage::IntegrityError` and nothing else, and ActiveJob does
      # not retry by default. They should retry the transient class too: `capacity` most obviously, and every
      # other transient verdict. The policy matches the one they already declare, so a cell failure and an
      # integrity failure back off the same way.
      #
      # Which of these classes exists depends on the Rails version, so a name that is not loaded is skipped.
      JOBS = %w[
        ActiveStorage::AnalyzeJob
        ActiveStorage::CreateVariantsJob
        ActiveStorage::PreviewImageJob
        ActiveStorage::TransformJob
      ].freeze

      RETRY = { wait: :polynomially_longer, attempts: 10 }.freeze

      # The clients this gem ships, which is where the retry hook learns which cells' transient classes
      # the jobs must retry. Listed rather than discovered, so an application's own clients for unrelated
      # cells stay out of it: Active Storage's jobs have no business retrying those.
      CLIENTS = [ Operations::Transformers::Image::Vips, Operations::Transformers::Image::Magick,
                  Operations::Analyzers::Image::Vips, Operations::Analyzers::Image::Magick,
                  Operations::Analyzers::Media::Ffprobe,
                  Operations::Previewers::Pdf::Mutool, Operations::Previewers::Pdf::Poppler,
                  Operations::Previewers::Video::Ffmpeg ].freeze

      class << self
        # The railtie calls this from a to_prepare block. Applied once at boot it would not survive a code
        # reload: a gem engine's app/jobs is in the reloadable autoloader, so these classes are discarded and
        # redefined, and the retry would silently disappear after the first file save in development.
        #
        # Every registered cell contributes its transient class, because the documented multi-cell
        # arrangement routes PreviewVideo to a cell of its own and each cell names its own class. A cell not
        # yet registered contributes nothing rather than raising: this runs on the boot where the application
        # has bundled the gem and not yet written the initializer, and that boot has to succeed for the
        # rollout to take two deploys rather than one.
        def retry_transient_failures!(jobs: JOBS)
          transients = CLIENTS.filter_map { |client| client.cell.transient if client.registered? }
                              .uniq
          return [] if transients.empty?

          jobs.filter_map(&:safe_constantize)
              .each { |job| job.retry_on(*transients, **RETRY) }
        end
      end
    end
  end
end
