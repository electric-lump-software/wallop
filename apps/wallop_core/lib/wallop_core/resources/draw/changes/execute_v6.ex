defmodule WallopCore.Resources.Draw.Changes.ExecuteV6 do
  @moduledoc """
  Executes a lock schema 6 draw (Met Office Land Observations or GB grid
  frequency). The caller supplies only the drand beacon; everything else
  comes from stored state.

  Inside the update's transaction it takes the draw's row lock and reads the
  draw again under it, then checks, in order:

    * the stored (lock_schema_version, entropy_composition) pair has rules
      (`WallopCore.Entropy.V6Rules`); otherwise `V6ExecRefused`;
    * the committed entries still hash to the stored `entry_hash`; otherwise
      `V6ExecRefused`, because no retry can change stored state;
    * the fetch deadline F has passed on the database clock, and the drand
      round has published; otherwise `V6NotYet`, with nothing written.

  Then it reads the stored reading for the draw's hour (Land Obs) or the
  stored window for its start T (grid frequency), under the row lock.
  If there is one, the seed uses it. Under Land Obs, with no reading it
  uses the round's stored grid-frequency window, and with neither it is
  drand only, all by rule from stored state. Under grid frequency, with no
  window it is drand only. The stores can no longer change after their
  deadlines, so there is no other choice to make. The
  attributes the tag sets come from `V6Rules.completion_attrs/2`.

  The draws guard refuses any completion that differs from the stored
  reading or the fallback rule, and refuses the fallback until a minute past
  F (Land Obs; drand only there also waits until M past T's F) or M past F
  (grid frequency). The execution receipt guard
  binds the signed receipt to the completed draw, its lock receipt and the
  stored reading or window (or the fallback rule), so a receipt that
  disagrees with any of them is refused too.
  """
  use Ash.Resource.Change

  alias WallopCore.DbClock
  alias WallopCore.Entropy.V6Rules
  alias WallopCore.Errors.{V6ExecRefused, V6NotYet}
  alias WallopCore.Repo
  alias WallopCore.Resources.Draw

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &run/1)

  defp run(changeset) do
    id = changeset.data.id
    Repo.query!("SELECT 1 FROM draws WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(id)])
    draw = Ash.get!(Draw, id, authorize?: false)

    case V6Rules.rules(draw) do
      {:ok, rules} ->
        check(changeset, rules, draw)

      :error ->
        message = V6Rules.unknown_pair_message(draw.lock_schema_version, draw.entropy_composition)
        refuse(changeset, message)
    end
  end

  defp check(changeset, rules, draw) do
    entries = WallopCore.Entries.load_for_draw(draw.id)
    {hash, _canonical} = WallopCore.Protocol.entry_hash({draw.id, entries})
    now = DbClock.now()
    deadline = V6Rules.fetch_deadline(rules, draw)
    pub = V6Rules.drand_pub_time(rules, draw)
    executed_at = DateTime.utc_now()

    cond do
      hash != draw.entry_hash ->
        refuse(
          changeset,
          "entry hash mismatch: the committed entries no longer hash to entry_hash"
        )

      DateTime.compare(now, deadline) != :gt ->
        not_yet(changeset, "the observation fetch window is still open", deadline)

      DateTime.compare(executed_at, pub) == :lt ->
        not_yet(changeset, "the drand round has not published yet", pub)

      true ->
        apply_results(changeset, rules, draw, entries, V6Rules.reading(rules, draw), executed_at)
    end
  end

  defp refuse(changeset, message),
    do: Ash.Changeset.add_error(changeset, V6ExecRefused.exception(message: message))

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

    %{
      results: results,
      seed: Base.encode16(seed_bytes, case: :lower),
      seed_source: :entropy,
      seed_json: seed_json,
      drand_randomness: randomness,
      drand_signature: Ash.Changeset.get_argument(changeset, :drand_signature),
      drand_response: Ash.Changeset.get_argument(changeset, :drand_response),
      executed_at: executed_at,
      status: :completed
    }
    |> Map.merge(V6Rules.completion_attrs(rules, reading))
    |> Enum.reduce(changeset, fn {attr, value}, cs ->
      Ash.Changeset.force_change_attribute(cs, attr, value)
    end)
  end
end
