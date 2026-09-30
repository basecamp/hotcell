# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"

begin
  require "action_controller"
rescue LoadError
  # The gem depends on Active Support alone; Action Pack rides in through the development bundle.
end

class ControllersTest < HotCellClientTest
  def setup
    skip "actionpack is not in this bundle" unless defined?(ActionController::Base)
    super
  end

  def test_health_answers_ok_when_every_registered_cell_answers
    with_cell do
      assert_equal [ 200, "text/plain", "OK" ], get(HotCell::HealthController)
    end
  end

  def test_health_answers_fail_when_no_cell_answers
    HotCell.register "missing", dir: "/nonexistent/hotcell/missing"

    assert_equal [ 503, "text/plain", "FAIL" ], get(HotCell::HealthController)
  end

  def test_diagnostics_answers_every_check_as_json
    with_cell operations: -> { require "hot_cell/health_operations" } do
      status, content_type, body = get(HotCell::DiagnosticsController)
      checks = JSON.parse(body).dig("cells", "test")

      assert_equal [ 200, "application/json" ], [ status, content_type ]
      assert_equal %w[ describe metrics echo reopen ], checks.keys
      assert(checks.each_value.all? { |check| check["ok"] })
    end
  end

  def test_diagnostics_answers_503_when_a_check_fails
    HotCell.register "missing", dir: "/nonexistent/hotcell/missing"

    status, _, body = get(HotCell::DiagnosticsController)

    assert_equal 503, status
    assert_equal false, JSON.parse(body)["healthy"]
  end

  # The superclass is fixed when the class body runs, so this needs a process that has not loaded it yet.
  def test_diagnostics_inherits_from_the_configured_parent
    script = <<~RUBY
      require "hot_cell/client"
      require "action_controller"
      class StaffController < ActionController::Base; end
      HotCell.diagnostics_controller_parent = "StaffController"
      print HotCell::DiagnosticsController.superclass
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)

    assert_predicate status, :success?, output
    assert_equal "StaffController", output
  end

  private
    def get(controller)
      status, headers, body = controller.action(:show).call(Rack::MockRequest.env_for("/"))
      text = +""
      body.each { |part| text << part }

      [ status, headers["content-type"].split(";").first, text ]
    end
end
