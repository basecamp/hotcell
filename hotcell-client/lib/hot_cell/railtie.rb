# frozen_string_literal: true

module HotCell
  # Loads the hotcell:install task into a Rails application. The gem works without Rails, so this file
  # is required only when Rails::Railtie is already defined.
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path("tasks/hotcell.rake", __dir__)
    end
  end
end
