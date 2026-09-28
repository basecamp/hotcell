# frozen_string_literal: true

require "hot_cell/log_subscriber"

module HotCell
  # Loads the hotcell:install task into a Rails application and logs each call. The gem works without
  # Rails, so this file is required only when Rails::Railtie is already defined.
  class Railtie < ::Rails::Railtie
    initializer "hot_cell.log_subscriber" do
      HotCell::LogSubscriber.attach_to :hot_cell
    end

    rake_tasks do
      load File.expand_path("tasks/hotcell.rake", __dir__)
    end
  end
end
