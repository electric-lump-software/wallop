defmodule WallopCore.Resources.Draw.Changes.ExecuteDrandOnly do
  @moduledoc """
  Executes a draw using drand entropy only (weather unavailable).

  Same protocol as ExecuteWithEntropy but omits weather from the seed
  computation. The weather_fallback_reason is stored in the proof record.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &run_draw/1)
  end

  defp run_draw(changeset) do
    draw = changeset.data
    atom_entries = WallopCore.Entries.load_for_draw(draw.id)

    {recomputed_hash, _canonical} = WallopCore.Protocol.entry_hash(atom_entries)

    if recomputed_hash != draw.entry_hash do
      Ash.Changeset.add_error(changeset, field: :entries, message: "entry hash mismatch")
    else
      apply_results(changeset, draw, atom_entries)
    end
  end

  defp apply_results(changeset, draw, atom_entries) do
    drand_randomness = Ash.Changeset.get_argument(changeset, :drand_randomness)
    drand_signature = Ash.Changeset.get_argument(changeset, :drand_signature)
    drand_response = Ash.Changeset.get_argument(changeset, :drand_response)
    weather_fallback_reason = Ash.Changeset.get_argument(changeset, :weather_fallback_reason)

    {seed_bytes, seed_json} =
      WallopCore.Protocol.compute_seed(draw.entry_hash, drand_randomness)

    seed_hex = Base.encode16(seed_bytes, case: :lower)
    results = FairPick.draw(atom_entries, seed_bytes, draw.winner_count)

    string_results =
      Enum.map(results, fn %{position: pos, entry_id: id} ->
        %{"position" => pos, "entry_id" => id}
      end)

    changeset
    |> Ash.Changeset.force_change_attribute(:results, string_results)
    |> Ash.Changeset.force_change_attribute(:seed, seed_hex)
    |> Ash.Changeset.force_change_attribute(:seed_source, :entropy)
    |> Ash.Changeset.force_change_attribute(:seed_json, seed_json)
    |> Ash.Changeset.force_change_attribute(:drand_randomness, drand_randomness)
    |> Ash.Changeset.force_change_attribute(:drand_signature, drand_signature)
    |> Ash.Changeset.force_change_attribute(:drand_response, drand_response)
    |> Ash.Changeset.force_change_attribute(:weather_value, nil)
    |> Ash.Changeset.force_change_attribute(:weather_raw, nil)
    |> Ash.Changeset.force_change_attribute(:weather_observation_time, nil)
    |> Ash.Changeset.force_change_attribute(:weather_fallback_reason, weather_fallback_reason)
    |> Ash.Changeset.force_change_attribute(:executed_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:status, :completed)
  end
end
