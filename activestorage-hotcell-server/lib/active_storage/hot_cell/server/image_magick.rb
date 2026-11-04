# frozen_string_literal: true

require "hot_cell/errors"

module ActiveStorage
  module HotCell
    module Server
      # Adds Rails' ImageMagick security policy to every ImageMagick a cell runs: the `identify` and `magick`
      # that mini_magick spawns, and `magickload` inside a worker. `image_magick/policy.xml` is Rails'
      # unchanged, from rails/rails@468aa9a93fc98f5476b6821770f4ccfcb7f7d328 (GHSA-f3w6-w445-fwh9).
      #
      # ImageMagick reads every `policy.xml` on its search path and applies all of them, and for a coder the
      # last rule that matches wins. `MAGICK_CONFIGURE_PATH` goes at the front of that path, ahead of the
      # system policy, so this directory goes first and whatever the image named stays after it: a policy
      # there, or the image's system `policy.xml`, can deny more or allow again.
      module ImageMagick
        POLICY_DIRECTORY = File.expand_path("image_magick", __dir__)

        # ImageMagick would split it, find no policy in either half, and run without it.
        if POLICY_DIRECTORY.include?(File::PATH_SEPARATOR)
          raise ::HotCell::ConfigurationError, "ImageMagick can't load the security policy from #{POLICY_DIRECTORY}, " \
            "because MAGICK_CONFIGURE_PATH splits at #{File::PATH_SEPARATOR.inspect}; install the gem elsewhere"
        end

        def self.configure_path(from_the_image)
          [ POLICY_DIRECTORY, *from_the_image.to_s.split(File::PATH_SEPARATOR) - [ POLICY_DIRECTORY, "" ] ]
            .join(File::PATH_SEPARATOR)
        end
      end
    end
  end
end

# In the supervisor's environment, at require, so that every worker inherits it and `magickload` reads it. That
# library reads its environment rather than mini_magick's, and reads the policy once per process, on first use.
ENV["MAGICK_CONFIGURE_PATH"] = ActiveStorage::HotCell::Server::ImageMagick.configure_path(ENV["MAGICK_CONFIGURE_PATH"])
