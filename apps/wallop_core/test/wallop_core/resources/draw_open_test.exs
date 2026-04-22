defmodule WallopCore.Resources.DrawOpenTest do
  @moduledoc """
  Tests for the open draw lifecycle:
  create (open) -> add_entries -> lock (awaiting_entropy)
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  defp with_prod_env(fun) do
    original = Application.get_env(:wallop_core, :env)
    Application.put_env(:wallop_core, :env, :prod)

    try do
      fun.()
    after
      Application.put_env(:wallop_core, :env, original)
    end
  end

  describe "create open draw" do
    test "creates a draw with status :open and no entries" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 2}, actor: api_key)
        |> Ash.create!()

      assert draw.status == :open
      assert draw.entry_count == 0
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

    test "accepts a name" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1, name: "Spring Raffle"},
          actor: api_key
        )
        |> Ash.create!()

      assert draw.name == "Spring Raffle"
    end

    test "name defaults to nil" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      assert draw.name == nil
    end

    test "rejects name longer than 255 characters" do
      api_key = create_api_key()
      long_name = String.duplicate("a", 256)

      assert_raise Ash.Error.Invalid, fn ->
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1, name: long_name}, actor: api_key)
        |> Ash.create!()
      end
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

    test "rejects invalid callback_url (HTTP) in prod" do
      api_key = create_api_key()

      with_prod_env(fn ->
        assert_raise Ash.Error.Invalid, fn ->
          WallopCore.Resources.Draw
          |> Ash.Changeset.for_create(
            :create,
            %{winner_count: 1, callback_url: "http://example.com/hook"},
            actor: api_key
          )
          |> Ash.create!()
        end
      end)
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
          %{entries: [%{"ref" => "a", "weight" => 1}, %{"ref" => "b", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      assert draw.entry_count == 2
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
          %{entries: [%{"ref" => "a", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"ref" => "b", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      assert draw.entry_count == 2

      table_entries = WallopCore.Entries.load_for_draw(draw.id)
      refs = Enum.map(table_entries, & &1.operator_ref)
      assert "a" in refs
      assert "b" in refs
    end

    test "enforces 10K entry limit" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      too_many = for i <- 1..10_001, do: %{"ref" => "entry-#{i}", "weight" => 1}

      assert_raise Ash.Error.Invalid, ~r/must not exceed 10000/, fn ->
        draw
        |> Ash.Changeset.for_update(:add_entries, %{entries: too_many}, actor: api_key)
        |> Ash.update!()
      end
    end
  end

  describe "remove_entry" do
    test "removes an entry by its wallop UUID" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"ref" => "a", "weight" => 1}, %{"ref" => "b", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      [to_remove, to_keep] =
        WallopCore.Entries.load_for_draw(draw.id) |> Enum.sort_by(& &1.operator_ref)

      draw =
        draw
        |> Ash.Changeset.for_update(:remove_entry, %{entry_uuid: to_remove.uuid}, actor: api_key)
        |> Ash.update!()

      assert draw.entry_count == 1

      remaining = WallopCore.Entries.load_for_draw(draw.id)
      assert length(remaining) == 1
      assert hd(remaining).uuid == to_keep.uuid
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
          %{entries: [%{"ref" => "a", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      assert_raise Ash.Error.Invalid, ~r/entry not found/, fn ->
        draw
        |> Ash.Changeset.for_update(
          :remove_entry,
          %{entry_uuid: "00000000-0000-4000-8000-000000000000"},
          actor: api_key
        )
        |> Ash.update!()
      end
    end

    test "cannot remove entry from a non-open draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.status == :awaiting_entropy

      assert_raise Ash.Error.Invalid, fn ->
        draw
        |> Ash.Changeset.for_update(
          :remove_entry,
          %{entry_uuid: "00000000-0000-4000-8000-000000000000"},
          actor: api_key
        )
        |> Ash.update!()
      end
    end
  end

  describe "update_name" do
    test "can rename an open draw" do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1, name: "Old Name"}, actor: api_key)
        |> Ash.create!()

      updated =
        draw
        |> Ash.Changeset.for_update(:update_name, %{name: "New Name"}, actor: api_key)
        |> Ash.update!()

      assert updated.name == "New Name"
    end

    test "cannot rename after locking" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert draw.status == :awaiting_entropy

      assert_raise Ash.Error.Forbidden, fn ->
        draw
        |> Ash.Changeset.for_update(:update_name, %{name: "Too Late"}, actor: api_key)
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
          %{entries: [%{"ref" => "a", "weight" => 1}, %{"ref" => "b", "weight" => 1}]},
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
          %{entries: [%{"ref" => "a", "weight" => 1}]},
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
          %{entries: [%{"ref" => "a", "weight" => 1}, %{"ref" => "b", "weight" => 1}]},
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
          %{entries: [%{"ref" => "extra", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()
      end
    end
  end
end
