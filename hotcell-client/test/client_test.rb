# frozen_string_literal: true

require "test_helper"

class ClientTest < HotCellClientTest
  def test_a_client_names_its_cell_and_its_operation
    assert_equal "test", Uppercase.hotcell
    assert_equal "test.uppercase", Uppercase.operation
  end

  def test_the_operation_name_defaults_to_the_underscored_class_name
    assert_equal "client_test.derived_name", DerivedName.operation
  end

  def test_a_subclass_inherits_the_cell_it_talks_to
    assert_equal "test", Specialized.hotcell
  end

  def test_a_client_with_no_cell_says_so
    error = assert_raises(HotCell::ConfigurationError) { Homeless.cell }

    assert_match "must name its cell", error.message
  end

  def test_every_client_is_discoverable_so_a_boot_check_can_find_it
    assert_includes HotCell.clients, Uppercase
  end

  # The caller is the one that knows what to do instead, so this is loud rather than silent.
  def test_calling_a_cell_whose_directory_is_unset
    HotCell.register "test"

    refute_predicate Uppercase, :enabled?
    assert_raises(HotCell::CellNotConfigured) { Uppercase.perform_in_hotcell [], [], {} }
  end

  # These are the caller's own bugs and they must be raised as themselves, above the transport's rescue. An
  # application whose transient class descends from IOError would otherwise have a bad call reclassified as a
  # socket failure and retried forever.
  def test_a_payload_value_json_cannot_carry_raises_rather_than_being_classified
    with_cell do
      assert_raises(HotCell::SerializationError) { Echo.perform_in_hotcell [], [], { format: :png } }
    end
  end

  def test_a_read_write_descriptor_as_an_input_raises_rather_than_being_classified
    with_cell do
      with_files do |source, destination|
        File.open(source, "r+b") do |readwrite|
          writing(destination) do |writable|
            assert_raises HotCell::AccessModeError do
              Uppercase.perform_in_hotcell [ readwrite ], [ writable ], {}
            end
          end
        end
      end
    end
  end

  def test_a_read_only_descriptor_as_an_output_raises_rather_than_being_classified
    with_cell do
      with_files do |source, destination|
        reading(source) do |readable|
          reading(destination) do |also_readable|
            assert_raises HotCell::AccessModeError do
              Uppercase.perform_in_hotcell [ readable ], [ also_readable ], {}
            end
          end
        end
      end
    end
  end

  def test_a_request_over_the_byte_limit_raises_rather_than_being_classified
    with_cell do
      assert_raises HotCell::MessageError do
        Echo.perform_in_hotcell [], [], { blob: "x" * HotCell::MAX_REQUEST_BYTES }
      end
    end
  end

  class Uppercase < HotCell::Client
    hotcell "test"
    operation "test.uppercase"
  end

  class Echo < HotCell::Client
    hotcell "test"
    operation "test.echo"
  end

  class Specialized < Uppercase; end

  class DerivedName < HotCell::Client
    hotcell "test"
  end

  class Homeless < HotCell::Client; end
end
