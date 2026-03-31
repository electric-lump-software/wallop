defmodule WallopCore.Resources.EntryTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Resources.Entry

  describe "create" do
    test "creates an entry with valid attributes" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      entry =
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          entry_id: "ticket-1",
          weight: 1
        })
        |> Ash.create!(authorize?: false)

      assert entry.draw_id == draw.id
      assert entry.entry_id == "ticket-1"
      assert entry.weight == 1
    end

    test "enforces unique (draw_id, entry_id)" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      Entry
      |> Ash.Changeset.for_create(:create, %{draw_id: draw.id, entry_id: "ticket-1", weight: 1})
      |> Ash.create!(authorize?: false)

      assert_raise Ash.Error.Invalid, fn ->
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          entry_id: "ticket-1",
          weight: 1
        })
        |> Ash.create!(authorize?: false)
      end
    end

    test "immutability trigger prevents insert on non-open draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.status == :awaiting_entropy

      assert_raise Ash.Error.Unknown, fn ->
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          entry_id: "sneaky",
          weight: 1
        })
        |> Ash.create!(authorize?: false)
      end
    end
  end
end
