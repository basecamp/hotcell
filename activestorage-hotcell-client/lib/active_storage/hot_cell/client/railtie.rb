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
      end
    end
  end
end
