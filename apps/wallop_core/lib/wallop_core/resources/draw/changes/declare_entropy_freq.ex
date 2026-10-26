defmodule WallopCore.Resources.Draw.Changes.DeclareEntropyFreq do
  @moduledoc """
  Declares entropy for a grid-frequency lock (lock schema 6, the
  `drand-quicknet+elexon-freq-v1` tag).

  From `draw_at` (or, when none is sent, `Schedule.default_draw_at/1`, the
  earliest allowed time) it derives, through `WallopCore.Frequency.Schedule`:

    * `drand_round`, the quicknet round that publishes at `draw_at`;
    * `freq_start`, the window start T that follows from that round;
    * `drand_chain`, the quicknet chain.

  Nothing is taken from the operator except `draw_at`. The weather fields
  stay null. Whether the lock is still in time is checked where `locked_at`
  is signed (`WallopCore.Resources.Draw.Changes.SignAndStoreReceipt`), and
  again by the database on its own clock and at commit.

  After the lock UPDATE, in the lock's own transaction, it inserts on
  core's Oban:

    * T's fetch job, `FrequencyWindowWorker.new_for_start/1`, which is
      unique per T and so shared by every draw of that window;
    * this draw's execution job, `ObservationDrawWorker`, at the result time
      plus `Schedule.execution_delay_seconds/0`.

  If either insert fails, the lock
  rolls back. The lock is broadcast once it has committed (an
  `after_transaction` hook), never from inside the transaction.
  """
  use Ash.Resource.Change

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{FrequencyWindowWorker, ObservationDrawWorker}
  alias WallopCore.Frequency.Schedule

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

    with {:ok, _} <- Oban.insert(FrequencyWindowWorker.new_for_start(draw.freq_start)),
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
