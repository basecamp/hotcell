# frozen_string_literal: true

require "hot_cell/client"

module ActiveStorage
  module HotCell
    module Client
      # The cell these all talk to by default. An application registers it under this name.
      CELL = "active_storage"

      # One client class per operation, named role, then subject, then tool — so lexical order groups
      # siblings — and the wire name is the snake-cased class path.
      #
      # They are separate classes so that they need not stay together. A cell carries one toolchain by design, so
      # an application that wants video previews in a cell with ffmpeg and variants in a cell with only libvips
      # says so here and changes nothing else:
      #
      #   ActiveStorage::HotCell::Client::Operations::Previewers::Video::Ffmpeg.hotcell "video"
      #
      # Routing is a class-level declaration rather than a call-site argument, so call sites carry no deployment
      # detail at all.
      module Operations
        module Transformers
          module Image
            class Vips < ::HotCell::Client
              hotcell CELL
              operation "active_storage.transformers.image.vips"
            end

            class Magick < ::HotCell::Client
              hotcell CELL
              operation "active_storage.transformers.image.magick"
            end
          end
        end

        module Analyzers
          module Image
            class Vips < ::HotCell::Client
              hotcell CELL
              operation "active_storage.analyzers.image.vips"
            end

            class Magick < ::HotCell::Client
              hotcell CELL
              operation "active_storage.analyzers.image.magick"
            end
          end

          # One probe serves both media analyzers: ffprobe reports video and audio streams in one pass, and
          # the video and audio analyzers each slice the shared result to their own keys.
          module Media
            class Ffprobe < ::HotCell::Client
              hotcell CELL
              operation "active_storage.analyzers.media.ffprobe"
            end

            FFprobe = Ffprobe
          end
        end

        module Previewers
          module Pdf
            class Mutool < ::HotCell::Client
              hotcell CELL
              operation "active_storage.previewers.pdf.mutool"
            end

            class Poppler < ::HotCell::Client
              hotcell CELL
              operation "active_storage.previewers.pdf.poppler"
            end
          end

          PDF = Pdf

          module Video
            class Ffmpeg < ::HotCell::Client
              hotcell CELL
              operation "active_storage.previewers.video.ffmpeg"
            end

            FFmpeg = Ffmpeg
          end
        end
      end
    end
  end
end
