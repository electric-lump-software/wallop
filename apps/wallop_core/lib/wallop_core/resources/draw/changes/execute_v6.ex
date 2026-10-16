defmodule WallopCore.Resources.Draw.Changes.ExecuteV6 do
  @moduledoc """
  Executes an observation-weather draw. The caller supplies only the drand
  beacon; everything else comes from stored state.

  Inside the update's transaction it takes the draw's row lock, then checks,
  in order:

    * the stored (lock_schema_version, entropy_composition) pair has rules
      (`WallopCore.Entropy.V6Rules`); otherwise `V6ExecRefused`;
    * the committed entries still hash to the stored `entry_hash`;
    * the fetch deadline F has passed on the database clock, and the drand
      round has published; otherwise `V6NotYet`, with nothing written.

  Then it reads the stored reading for the draw's hour, under the row lock.
  If there is one, the seed uses it. If there is none, the draw is
  drand-only with the rules' fallback reason: by rule, because the store
  can no longer change after F. There is no other choice to make.

  The draws guard refuses any completion that differs from the stored
  reading or the fallback rule.
  """
  use Ash.Resource.Change

  alias WallopCore.Entropy.V6Rules
  alias WallopCore.Errors.{V6ExecRefused, V6NotYet}
  alias WallopCore.Repo
  alias WallopCore.Weather.Observations

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &run/1)

  defp run(changeset) do
    draw = changeset.data

    case rules(draw) do
      {:ok, rules} ->
        Repo.query!("SELECT 1 FROM draws WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(draw.id)])
        check(changeset, rules, draw)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, V6ExecRefused.exception(message: message))
    end
  end

  defp rules(draw) do
    {:ok, V6Rules.rules!(draw)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp check(changeset, rules, draw) do
    entries = WallopCore.Entries.load_for_draw(draw.id)
    {hash, _canonical} = WallopCore.Protocol.entry_hash({draw.id, entries})
    now = Observations.db_now()
    deadline = V6Rules.fetch_deadline(rules, draw)
    pub = V6Rules.drand_pub_time(rules, draw)
    executed_at = DateTime.utc_now()

    cond do
      hash != draw.entry_hash ->
        Ash.Changeset.add_error(changeset, field: :entries, message: "entry hash mismatch")

      DateTime.compare(now, deadline) != :gt ->
        not_yet(changeset, "the observation fetch window is still open", deadline)

      DateTime.compare(executed_at, pub) == :lt ->
        not_yet(changeset, "the drand round has not published yet", pub)

      true ->
        apply_results(changeset, rules, draw, entries, V6Rules.reading(rules, draw), executed_at)
    end
  end

  defp not_yet(changeset, message, retry_at),
    do:
      Ash.Changeset.add_error(changeset, V6NotYet.exception(message: message, retry_at: retry_at))

  defp apply_results(changeset, rules, draw, entries, reading, executed_at) do
    randomness = Ash.Changeset.get_argument(changeset, :drand_randomness)
    {seed_bytes, seed_json} = V6Rules.seed(rules, draw.entry_hash, randomness, reading)

    results =
      entries
      |> Enum.map(&%{id: &1.uuid, weight: &1.weight})
      |> FairPick.draw(seed_bytes, draw.winner_count)
      |> Enum.map(fn %{position: p, entry_id: id} -> %{"position" => p, "entry_id" => id} end)

    fallback_reason = if reading, do: nil, else: V6Rules.fallback_reason(rules)

    changeset
    |> Ash.Changeset.force_change_attribute(:results, results)
    |> Ash.Changeset.force_change_attribute(:seed, Base.encode16(seed_bytes, case: :lower))
    |> Ash.Changeset.force_change_attribute(:seed_source, :entropy)
    |> Ash.Changeset.force_change_attribute(:seed_json, seed_json)
    |> Ash.Changeset.force_change_attribute(:drand_randomness, randomness)
    |> Ash.Changeset.force_change_attribute(
      :drand_signature,
      Ash.Changeset.get_argument(changeset, :drand_signature)
    )
    |> Ash.Changeset.force_change_attribute(
      :drand_response,
      Ash.Changeset.get_argument(changeset, :drand_response)
    )
    |> Ash.Changeset.force_change_attribute(:weather_value, reading && reading.value)
    |> Ash.Changeset.force_change_attribute(:weather_raw, reading && reading.raw)
    |> Ash.Changeset.force_change_attribute(
      :weather_observation_time,
      reading && reading.observation_time
    )
    |> Ash.Changeset.force_change_attribute(:weather_fallback_reason, fallback_reason)
    |> Ash.Changeset.force_change_attribute(:executed_at, executed_at)
    |> Ash.Changeset.force_change_attribute(:status, :completed)
  end
end
