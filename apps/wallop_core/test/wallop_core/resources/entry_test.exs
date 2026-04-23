defmodule WallopCore.Resources.EntryTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Resources.{Draw, Entry}

  setup do
    api_key = create_api_key()

    draw =
      Draw
      |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
      |> Ash.create!()

    %{draw: draw, api_key: api_key}
  end

  describe "create" do
    test "id is auto-generated UUID", %{draw: draw} do
      {:ok, entry} =
        Entry
        |> Ash.Changeset.for_create(:create, %{draw_id: draw.id, weight: 1})
        |> Ash.create(authorize?: false)

      assert is_binary(entry.id)

      assert String.match?(
               entry.id,
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
             )
    end

    test "immutability trigger prevents insert on non-open draw", %{api_key: api_key} do
      draw = create_draw(api_key)
      assert draw.status == :awaiting_entropy

      assert_raise Ash.Error.Unknown, fn ->
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          weight: 1
        })
        |> Ash.create!(authorize?: false)
      end
    end
  end
end
