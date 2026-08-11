# frozen_string_literal: true

namespace :hotcell do
  desc "Install the hotcell/ directory: a Dockerfile to customize, the cell's Gemfile, and operations/"
  task :install do
    require "hot_cell/install"

    HotCell::Install.call Rails.root
  end
end
