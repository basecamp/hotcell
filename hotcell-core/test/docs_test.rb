# frozen_string_literal: true

require "test_helper"

# The reference pages describe behavior, and these fail when a table there stops matching the code.
class DocsTest < HotCellTest
  DOCS = File.expand_path("../../docs", __dir__)

  def test_the_codes_table_gives_each_code_its_split
    documented = table("codes.md", "Code").reject { |code, *| code == "`killed`" }.to_h do |code, split, *|
      [ unquote(code), split == "Permanent" ]
    end

    assert_equal HotCell::Codes::PERMANENT.sort.to_h, documented.sort.to_h
  end

  def test_the_causes_table_gives_each_kill_cause_its_split
    documented = table("codes.md", "Cause").to_h { |cause, split, *| [ unquote(cause), split == "Permanent" ] }

    assert_equal HotCell::Codes::PERMANENT_BY_CAUSE.sort.to_h, documented.sort.to_h
  end

  private
    def unquote(cell)
      cell.delete_prefix("`").delete_suffix("`")
    end

    def table(page, first_header)
      lines = File.readlines(File.join(DOCS, page), chomp: true)
      header = lines.index { |line| line.start_with?("| #{first_header} |") }
      flunk "#{page} has no table headed #{first_header.inspect}" if header.nil?

      lines.drop(header + 2).take_while { |line| line.start_with?("|") }.map do |line|
        line.delete_prefix("|").delete_suffix("|").split(" | ").map(&:strip)
      end
    end
end
