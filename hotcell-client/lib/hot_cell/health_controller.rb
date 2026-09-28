# frozen_string_literal: true

require "action_controller"

module HotCell
  # Safe to leave unauthenticated: it asks the control socket only, so a poll takes no worker, and it answers
  # nothing but OK or FAIL.
  class HealthController < ActionController::Base
    def show
      healthy = HotCell.diagnose.healthy?

      render plain: healthy ? "OK" : "FAIL", status: healthy ? :ok : :service_unavailable
    end
  end
end
