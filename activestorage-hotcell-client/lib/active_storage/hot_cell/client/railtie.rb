# frozen_string_literal: true

require "rails/railtie"

module ActiveStorage
  module HotCell
    module Client
      # An application installs the transformer, the analyzer and the previewers itself, because Active Storage
      # reads those from config and there is no way for a gem to set them that the engine does not later
      # overwrite. Everything else this gem needs is done here.
      class Railtie < ::Rails::Railtie
        # on_load rather than to_prepare, because to_prepare runs while the application is initializing, and
        # loading a job there loads Active Job, which Rails' guard_load_hooks reports when eager loading is off.
        # on_load also runs again each time a job is reloaded, and never for a job the application's Rails
        # version does not have.
        initializer "active_storage.hot_cell.client.retry_transient_failures" do
          ActiveStorage::HotCell::Client::JOBS.each do |name|
            Rails.autoloaders.main.on_load(name) do |job|
              ActiveStorage::HotCell::Client.retry_transient_failures! job
            end
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
