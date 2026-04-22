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

    test "operator_ref is nullable", %{draw: draw} do
      {:ok, entry} =
        Entry
        |> Ash.Changeset.for_create(:create, %{draw_id: draw.id, weight: 1, operator_ref: nil})
        |> Ash.create(authorize?: false)

      assert entry.operator_ref == nil
    end

    test "operator_ref accepts a short string", %{draw: draw} do
      {:ok, entry} =
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          weight: 1,
          operator_ref: "ticket-47"
        })
        |> Ash.create(authorize?: false)

      assert entry.operator_ref == "ticket-47"
    end

    test "operator_ref accepts exactly 64 bytes", %{draw: draw} do
      sixty_four = String.duplicate("a", 64)

      {:ok, entry} =
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          weight: 1,
          operator_ref: sixty_four
        })
        |> Ash.create(authorize?: false)

      assert byte_size(entry.operator_ref) == 64
    end

    test "operator_ref rejects > 64 bytes", %{draw: draw} do
      assert {:error, _} =
               Entry
               |> Ash.Changeset.for_create(:create, %{
                 draw_id: draw.id,
                 weight: 1,
                 operator_ref: String.duplicate("a", 65)
               })
               |> Ash.create(authorize?: false)
    end

    test "operator_ref rejects multi-byte unicode over 64 bytes", %{draw: draw} do
      # 33 × "é" = 66 bytes (2 bytes each in UTF-8), 33 codepoints.
      # Limit is bytes, so this must reject even though codepoints < 64.
      assert {:error, _} =
               Entry
               |> Ash.Changeset.for_create(:create, %{
                 draw_id: draw.id,
                 weight: 1,
                 operator_ref: String.duplicate("é", 33)
               })
               |> Ash.create(authorize?: false)
    end

    test "operator_ref rejects control chars", %{draw: draw} do
      for bad <- ["\x00foo", "foo\x1F", "foo\x7F", "line1 line2", "para end"] do
        assert {:error, _} =
                 Entry
                 |> Ash.Changeset.for_create(:create, %{
                   draw_id: draw.id,
                   weight: 1,
                   operator_ref: bad
                 })
                 |> Ash.create(authorize?: false)
      end
    end

    test "duplicate operator_ref in same draw is allowed (no dedup)", %{draw: draw} do
      {:ok, _first} =
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          weight: 1,
          operator_ref: "same"
        })
        |> Ash.create(authorize?: false)

      # Second insert with identical ref should succeed — dedup is operator's concern.
      {:ok, _second} =
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          weight: 1,
          operator_ref: "same"
        })
        |> Ash.create(authorize?: false)
    end

    test "immutability trigger prevents insert on non-open draw", %{api_key: api_key} do
      draw = create_draw(api_key)
      assert draw.status == :awaiting_entropy

      assert_raise Ash.Error.Unknown, fn ->
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          weight: 1,
          operator_ref: "sneaky"
        })
        |> Ash.create!(authorize?: false)
      end
    end
  end
end
