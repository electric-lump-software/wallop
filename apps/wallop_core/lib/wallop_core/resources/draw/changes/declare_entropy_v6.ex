defmodule WallopCore.Resources.Draw.Changes.DeclareEntropyV6 do
  @moduledoc """
  Declares entropy for an observation-weather lock (lock schema 6).

  From `draw_at` (or, when none is sent, `Schedule.default_draw_at/1`, the
  earliest allowed time) it derives, through `WallopCore.Weather.Schedule`:

    * `drand_round`, the quicknet round that publishes at `draw_at`;
    * `weather_time`, the observation hour that follows from that round;
    * `freq_start`, the grid-frequency window start of that round, used if
      the hour's reading isn't stored by F;
    * `weather_station`, the tag's primary station;
    * `drand_chain`, the quicknet chain.

  Nothing is taken from the operator except `draw_at`. Whether the lock is
  still in time is checked where `locked_at` is signed
  (`WallopCore.Resources.Draw.Changes.SignAndStoreReceipt`), and again by
  the database on its own clock.

  After the lock UPDATE, in the lock's own transaction, it inserts on
  core's Oban:

    * the hour's fetch job, `WeatherObservationWorker.new_for_hour/1`, which
      is unique per hour and so shared by every draw of that hour;
    * this draw's execution job, `ObservationDrawWorker`, at the result time
      plus `Schedule.execution_delay_seconds/0`.

  It never inserts an `EntropyWorker` job. If either insert fails, the lock
  rolls back. The lock is broadcast once it has committed (an
  `after_transaction` hook), never from inside the transaction.
  """
  use Ash.Resource.Change

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{ObservationDrawWorker, WeatherObservationWorker}
  alias WallopCore.Weather.{Schedule, Stations}

  @impl true
  def change(%{errors: [_ | _]} = changeset, _opts, _context), do: changeset

  def change(changeset, _opts, _context) do
    draw_at =
      Ash.Changeset.get_argument(changeset, :draw_at) ||
        Schedule.default_draw_at(DateTime.utc_now())

    case Schedule.schedule(draw_at) do
      {:ok, s} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:drand_chain, Quicknet.chain_hash())
        |> Ash.Changeset.force_change_attribute(:drand_round, s.round)
        |> Ash.Changeset.force_change_attribute(:weather_station, Stations.primary().id)
        |> Ash.Changeset.force_change_attribute(:weather_time, s.weather_time)
        |> Ash.Changeset.force_change_attribute(:freq_start, s.freq_start)
        |> Ash.Changeset.force_change_attribute(:status, :awaiting_entropy)
        |> Ash.Changeset.after_action(fn _changeset, draw -> enqueue(draw) end)
        |> Ash.Changeset.after_transaction(&announce/2)

      # Never lock without a schedule.
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :draw_at,
          message: "is not a valid draw time (#{reason})"
        )
    end
  end

  defp enqueue(draw) do
    execute =
      ObservationDrawWorker.new(%{draw_id: draw.id},
        scheduled_at:
          DateTime.add(Schedule.pub_time(draw.drand_round), Schedule.execution_delay_seconds())
      )

    with {:ok, _} <- Oban.insert(WeatherObservationWorker.new_for_hour(draw.weather_time)),
         {:ok, _} <- Oban.insert(execute) do
      {:ok, draw}
    end
  end

  # The lock is announced once it has committed: a lock that rolls back,
  # at any step, is never announced.
  defp announce(_changeset, {:ok, draw} = result) do
    WallopCore.DrawPubSub.broadcast(draw)
    result
  end

  defp announce(_changeset, error), do: error
end
