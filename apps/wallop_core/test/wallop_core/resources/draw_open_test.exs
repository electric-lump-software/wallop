defmodule WallopCore.Resources.DrawOpenTest do
  @moduledoc """
  Tests for the open draw lifecycle:
  create (open) -> add_entries -> lock (awaiting_entropy)
  """
  use WallopCore.DataCase, async: true

  import WallopCore.TestHelpers

  describe "create open draw" do
    test "creates a draw with status :open and no entries" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 2}, actor: api_key)
        |> Ash.create!()

      assert draw.status == :open
      assert draw.entries == []
      assert draw.entry_hash == nil
      assert draw.entry_canonical == nil
      assert draw.winner_count == 2
    end

    test "records opened_at in stage_timestamps" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      assert draw.stage_timestamps["opened_at"] != nil
    end

    test "accepts metadata and callback_url" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(
          :create,
          %{
            winner_count: 1,
            metadata: %{"event" => "raffle"},
            callback_url: "https://example.com/hook"
          },
          actor: api_key
        )
        |> Ash.create!()

      assert draw.metadata == %{"event" => "raffle"}
      assert draw.callback_url == "https://example.com/hook"
    end

    test "rejects invalid callback_url (HTTP)" do
      api_key = create_api_key()

      assert_raise Ash.Error.Invalid, fn ->
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(
          :create,
          %{winner_count: 1, callback_url: "http://example.com/hook"},
          actor: api_key
        )
        |> Ash.create!()
      end
    end
  end

  describe "add_entries" do
    test "appends entries to an open draw" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}, %{"id" => "b", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      assert length(draw.entries) == 2
      assert draw.status == :open
    end

    test "appends multiple batches" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "b", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      assert length(draw.entries) == 2
      ids = Enum.map(draw.entries, & &1["id"])
      assert "a" in ids
      assert "b" in ids
    end

    test "rejects duplicate IDs against existing entries" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      assert_raise Ash.Error.Invalid, ~r/duplicate entry IDs/, fn ->
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()
      end
    end

    test "rejects duplicate IDs within a single batch" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      assert_raise Ash.Error.Invalid, ~r/duplicate entry IDs within batch/, fn ->
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "x", "weight" => 1}, %{"id" => "x", "weight" => 2}]},
          actor: api_key
        )
        |> Ash.update!()
      end
    end

    test "enforces 10K entry limit" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      # Create 10001 entries
      too_many = for i <- 1..10_001, do: %{"id" => "entry-#{i}", "weight" => 1}

      assert_raise Ash.Error.Invalid, ~r/must not exceed 10000/, fn ->
        draw
        |> Ash.Changeset.for_update(:add_entries, %{entries: too_many}, actor: api_key)
        |> Ash.update!()
      end
    end
  end

  describe "remove_entry" do
    test "removes an entry by ID" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}, %{"id" => "b", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      draw =
        draw
        |> Ash.Changeset.for_update(:remove_entry, %{entry_id: "a"}, actor: api_key)
        |> Ash.update!()

      assert length(draw.entries) == 1
      assert hd(draw.entries)["id"] == "b"
    end

    test "returns error if entry not found" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      assert_raise Ash.Error.Invalid, ~r/entry not found/, fn ->
        draw
        |> Ash.Changeset.for_update(:remove_entry, %{entry_id: "nonexistent"}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "cannot remove entry from a non-open draw" do
      api_key = create_api_key()
      # create_manual produces a locked draw
      draw = create_draw(api_key)

      assert draw.status == :locked

      assert_raise Ash.Error.Forbidden, fn ->
        draw
        |> Ash.Changeset.for_update(:remove_entry, %{entry_id: "ticket-47"}, actor: api_key)
        |> Ash.update!()
      end
    end
  end

  describe "lock" do
    test "computes entry hash and declares entropy" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}, %{"id" => "b", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
        |> Ash.update!()

      assert locked.status == :awaiting_entropy
      assert locked.entry_hash != nil
      assert locked.entry_canonical != nil
      assert locked.drand_round != nil
      assert locked.drand_chain != nil
      assert locked.weather_station != nil
      assert locked.weather_time != nil
    end

    test "records locked_at and entropy_declared_at timestamps" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
        |> Ash.update!()

      assert locked.stage_timestamps["locked_at"] != nil
      assert locked.stage_timestamps["entropy_declared_at"] != nil
    end

    test "rejects lock when draw has no entries" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      assert_raise Ash.Error.Invalid, ~r/draw has no entries/, fn ->
        draw
        |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "rejects lock when entries < winner_count" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 3}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}, %{"id" => "b", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      assert_raise Ash.Error.Invalid, ~r/entries .* must be >= winner_count/, fn ->
        draw
        |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "cannot lock an already locked draw" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert draw.status == :awaiting_entropy

      assert_raise Ash.Error.Forbidden, fn ->
        draw
        |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "cannot add entries after lock" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert draw.status == :awaiting_entropy

      assert_raise Ash.Error.Forbidden, fn ->
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "extra", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()
      end
    end
  end
end
