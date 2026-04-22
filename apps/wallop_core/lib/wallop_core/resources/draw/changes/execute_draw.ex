defmodule WallopCore.Resources.Draw.Changes.ExecuteDraw do
  @moduledoc """
  Executes a locked draw: verifies entry integrity, runs the FairPick algorithm,
  and stores the results.

  Uses `before_action` so all changes are applied in a single DB write.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&run_draw/1)
    |> Ash.Changeset.after_action(fn _changeset, draw ->
      WallopCore.DrawPubSub.broadcast(draw)
      {:ok, draw}
    end)
  end

  defp run_draw(changeset) do
    draw = changeset.data
    seed_hex = Ash.Changeset.get_argument(changeset, :seed)
    entries = WallopCore.Entries.load_for_draw(draw.id)

    # Integrity check: recompute entry hash and verify it matches
    {recomputed_hash, _canonical} = WallopCore.Protocol.entry_hash({draw.id, entries})

    if recomputed_hash != draw.entry_hash do
      Ash.Changeset.add_error(changeset, field: :entries, message: "entry hash mismatch")
    else
      apply_results(changeset, entries, seed_hex, draw.winner_count)
    end
  end

  defp apply_results(changeset, entries, seed_hex, winner_count) do
    seed_bytes = Base.decode16!(seed_hex, case: :mixed)
    fair_pick_entries = Enum.map(entries, &%{id: &1.uuid, weight: &1.weight})
    results = FairPick.draw(fair_pick_entries, seed_bytes, winner_count)

    string_results =
      Enum.map(results, fn %{position: pos, entry_id: id} ->
        %{"position" => pos, "entry_id" => id}
      end)

    changeset
    |> Ash.Changeset.force_change_attribute(:results, string_results)
    |> Ash.Changeset.force_change_attribute(:seed, seed_hex)
    |> Ash.Changeset.force_change_attribute(:seed_source, :caller)
    |> Ash.Changeset.force_change_attribute(:seed_json, nil)
    |> Ash.Changeset.force_change_attribute(:executed_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:status, :completed)
  end
end
