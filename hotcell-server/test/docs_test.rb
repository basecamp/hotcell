# frozen_string_literal: true

require "test_helper"

# The reference pages describe behavior, and these fail when a table there stops matching the code.
class DocsTest < HotCellServerTest
  DOCS = File.expand_path("../../docs", __dir__)

  def test_the_event_table_lists_every_event_at_its_level
    documented = table("observability.md", "`event.action`", under: "Events").to_h { |event, level, *| [ unquote(event), level ] }

    assert_equal HotCell::Log::LEVELS.sort.to_h, documented.sort.to_h
  end

  def test_the_cell_settings_tables_carry_the_defaults
    scheduling = defaults_in("Scheduling settings")
    limits = defaults_in("Request limits")

    assert_equal HotCell::Configuration::SCHEDULING, scheduling
    assert_equal HotCell::Configuration::LIMITS, limits
  end

  private
    def defaults_in(heading)
      table("cell-settings.md", "Setting", under: heading).to_h do |setting, default, *|
        [ unquote(setting).to_sym, number(unquote(default)) ]
      end
    end

    def number(text)
      text.end_with?("MB") ? Integer(text.delete_suffix("MB")) * 1024**2 : Integer(text)
    end

    def unquote(cell)
      cell.delete_prefix("`").delete_suffix("`")
    end

    # The rows of the first table whose header starts with `first_header`, after the `under` heading if one is
    # given.
    def table(page, first_header, under: nil)
      lines = File.readlines(File.join(DOCS, page), chomp: true)
      lines = lines.drop_while { |line| !line.match?(/\A#+ #{Regexp.escape(under)}\z/) } if under
      header = lines.index { |line| line.start_with?("| #{first_header} |") }
      flunk "#{page} has no table headed #{first_header.inspect}" if header.nil?

      lines.drop(header + 2).take_while { |line| line.start_with?("|") }.map do |line|
        line.delete_prefix("|").delete_suffix("|").split(" | ").map(&:strip)
      end
    end
end
