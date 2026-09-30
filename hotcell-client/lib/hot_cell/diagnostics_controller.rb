# frozen_string_literal: true

require "action_controller"

module HotCell
  # Each request takes a worker per round trip, so put this behind authentication.
  class DiagnosticsController < HotCell.diagnostics_controller_parent.constantize
    def show
      diagnosis = HotCell.diagnose(work: true)

      render json: diagnosis, status: diagnosis.healthy? ? :ok : :service_unavailable
    end
  end
end
