# frozen_string_literal: true

require "hot_cell/client"

module ActiveStorage
  module HotCell
    # The cell these all talk to by default. An application registers it under this name.
    CELL = "active_storage"

    # One client class per operation.
    #
    # **Namespaced apart from the operation classes of the same name in activestorage-hotcell-server.** The two
    # gems are never both loaded in production, and that turns out not to be enough: a cell is forked from a
    # process that may well have loaded the client, and the child then meets these constants before defining its
    # own. The collision is a superclass mismatch while the cell boots, which is a poor way to find out.
    #
    # They are separate classes so that they need not stay together. A cell carries one toolchain by design, so
    # an application that wants video previews in a cell with ffmpeg and variants in a cell with only libvips
    # says so here and changes nothing else:
    #
    #   ActiveStorage::HotCell::Clients::PreviewVideo.hotcell "video"
    #
    # Routing is a class-level declaration rather than a call-site argument, so call sites carry no deployment
    # detail at all.
    module Clients
      class TransformImage < ::HotCell::Client
        hotcell CELL
        operation "active_storage.transform_image"
      end

      class AnalyzeImage < ::HotCell::Client
        hotcell CELL
        operation "active_storage.analyze_image"
      end

      class PreviewPdf < ::HotCell::Client
        hotcell CELL
        operation "active_storage.preview_pdf"
      end

      class PreviewVideo < ::HotCell::Client
        hotcell CELL
        operation "active_storage.preview_video"
      end

      class ProbeMedia < ::HotCell::Client
        hotcell CELL
        operation "active_storage.probe_media"
      end
    end
  end
end
