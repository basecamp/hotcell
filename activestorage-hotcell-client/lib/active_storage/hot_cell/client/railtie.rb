# frozen_string_literal: true

require "rails/railtie"

module ActiveStorage
  module HotCell
    module Client
      # An application installs the transformer, the analyzer and the previewers itself, because Active Storage
      # reads those from config and there is no way for a gem to set them that the engine does not later
      # overwrite. Everything else this gem needs is done here.
      class Railtie < ::Rails::Railtie
        # to_prepare rather than after_initialize, because it runs again on every code reload and the job
        # classes do not survive one. See retry_transient_failures!.
        initializer "active_storage.hot_cell.client.retry_transient_failures" do |app|
          app.config.to_prepare do
            ActiveStorage::HotCell::Client.retry_transient_failures!
          end
        end

        # The two settings rails/rails#58461 adds, copied from `config.active_storage.*` the way Rails' engine
        # copies every other Active Storage setting — in after_initialize, once the environment file has run.
        # On a Rails that already has them, its engine did this already and the same value lands twice.
        #
        # The engine creates `config.active_storage`; an application that has not loaded it has no such
        # namespace, and then there is nothing to copy.
        initializer "active_storage.hot_cell.client.tool_arguments" do
          config.after_initialize do |app|
            next unless app.config.respond_to?(:active_storage)

            ActiveStorage.ffprobe_arguments = app.config.active_storage.ffprobe_arguments || ""
            ActiveStorage.video_preview_input_arguments = app.config.active_storage.video_preview_input_arguments || ""
          end
        end
      end
    end
  end
end
