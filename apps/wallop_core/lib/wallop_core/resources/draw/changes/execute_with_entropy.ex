defmodule WallopCore.Resources.Draw.Changes.ExecuteWithEntropy do
  @moduledoc """
  Executes a draw using entropy-derived seed.

  Receives drand and weather entropy arguments, computes the seed via the
  commit-reveal protocol, runs the FairPick algorithm, and stores the results.

  Uses `before_action` so all changes are applied in a single DB write.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &run_draw/1)
  end

  defp run_draw(changeset) do
    draw = changeset.data
    atom_entries = WallopCore.Entries.load_for_draw(draw.id)

    # Integrity check: recompute entry hash and verify it matches
    {recomputed_hash, _canonical} = WallopCore.Protocol.entry_hash(atom_entries)

    weather_observation_time = Ash.Changeset.get_argument(changeset, :weather_observation_time)

    cond do
      recomputed_hash != draw.entry_hash ->
        Ash.Changeset.add_error(changeset, field: :entries, message: "entry hash mismatch")

      draw.weather_time != nil and
          abs(DateTime.diff(weather_observation_time, draw.weather_time, :second)) > 3600 ->
        Ash.Changeset.add_error(changeset,
          field: :weather_observation_time,
          message: "observation must be within 1 hour of declared weather_time"
        )

      true ->
        apply_results(changeset, draw, atom_entries)
    end
  end

  defp apply_results(changeset, draw, atom_entries) do
    drand_randomness = Ash.Changeset.get_argument(changeset, :drand_randomness)
    drand_signature = Ash.Changeset.get_argument(changeset, :drand_signature)
    drand_response = Ash.Changeset.get_argument(changeset, :drand_response)
    weather_value = Ash.Changeset.get_argument(changeset, :weather_value)
    weather_raw = Ash.Changeset.get_argument(changeset, :weather_raw)
    weather_observation_time = Ash.Changeset.get_argument(changeset, :weather_observation_time)

    {seed_bytes, seed_json} =
      WallopCore.Protocol.compute_seed(draw.entry_hash, drand_randomness, weather_value)

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
    |> Ash.Changeset.force_change_attribute(:weather_value, weather_value)
    |> Ash.Changeset.force_change_attribute(:weather_raw, weather_raw)
    |> Ash.Changeset.force_change_attribute(:weather_observation_time, weather_observation_time)
    |> Ash.Changeset.force_change_attribute(:executed_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:status, :completed)
  end
end
