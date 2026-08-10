# frozen_string_literal: true

require "test_helper"

# A deployment runs one or more cells, each an independent process on its own socket, with its own consist,
# concurrency limit, deadline, and image. A cell does not know it has siblings; multiplicity is entirely a
# cold-side and deployment concern.
#
# This is how toolchains stay apart. What a test on one host can hold is that each cell is a separate process
# with its own sockets and its own scheduling, and that a client reaches the one it named. The last part of
# invariant 7 — that a compromised cell cannot reach another cell's socket — is a property of the mount
# topology and can only be shown against containers.
class TwoCellsTest < HotCellClientTest
  def test_a_client_reaches_the_cell_it_named
    with_two_cells do |images, documents|
      assert_equal File.join(images.workspace, "0", "home"), Thumbnail.perform_in_hotcell([], [], {})[:home]
      assert_equal File.join(documents.workspace, "0", "home"), Preview.perform_in_hotcell([], [], {})[:home]
    end
  end

  def test_each_cell_keeps_its_sockets_in_its_own_directory
    with_two_cells do |images, documents|
      refute_equal images.directory, documents.directory

      [ images, documents ].each do |cell|
        assert_equal [ "control.sock", "work.sock" ], Dir.children(cell.directory).sort
      end
    end
  end

  # Work inside a cell competes for one concurrency limit, first come first served, with no per-operation
  # priority. So a video preview measured in minutes and an avatar thumbnail measured in milliseconds must not
  # share a cell — separating them is what a second cell is for.
  def test_saturating_one_cell_leaves_the_other_serving
    with_two_cells(images: { concurrency: 1, queue_size: 0, deadline: 30 }) do |_images, _documents|
      held = UNIXSocket.new HotCell.cell("images").work_socket

      begin
        HotCell::Connection.new(held).send_message(
          HotCell::Request.new(op: "test.blocking", payload: { seconds: 0.6 }).to_line
        )
        # assert_raises returns the exception, so putting it inside wait_until makes the first attempt the only
        # attempt. Wait on the plain condition, then assert once it holds.
        wait_until(what: "the images cell to saturate") { refused?(Thumbnail) }

        assert_raises(TemporarilyUnavailable) { Thumbnail.perform_in_hotcell [], [], {} }
        assert Preview.perform_in_hotcell([], [], {})[:home], "the documents cell should be unaffected"
      ensure
        held.close
      end
    end
  end

  def test_each_cell_reports_its_own_configuration
    with_two_cells(images: { deadline: 11 }, documents: { deadline: 22 }) do
      described = HotCell.describe_cells

      assert_equal 11, described["images"][:deadline]
      assert_equal 22, described["documents"][:deadline]
    end
  end

  class Thumbnail < HotCell::Client
    hotcell "images"
    operation "test.whereami"
  end

  class Preview < HotCell::Client
    hotcell "documents"
    operation "test.whereami"
  end

  private
    def with_two_cells(images: {}, documents: {})
      HotCell::TestCell.boot(name: "images", **images) do |images_cell|
        HotCell::TestCell.boot(name: "documents", **documents) do |documents_cell|
          # Registered by directory rather than by root, because these two cells are not siblings on disk
          # here. A deployment would mount one volume per cell under a shared root.
          [ [ "images", images_cell ], [ "documents", documents_cell ] ].each do |name, cell|
            HotCell.register name, dir: cell.directory, permanent: Unprocessable,
                                   transient: TemporarilyUnavailable
          end

          yield images_cell, documents_cell
        end
      end
    end

    def refused?(client)
      client.perform_in_hotcell [], [], {}
      false
    rescue TemporarilyUnavailable
      true
    end
end
