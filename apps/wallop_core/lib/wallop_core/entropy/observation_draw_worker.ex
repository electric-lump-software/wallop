defmodule WallopCore.Entropy.ObservationDrawWorker do
  @moduledoc """
  Executes a lock schema 6 draw (Met Office Land Observations or GB grid
  frequency) at its result time. Dispatches on the draw's stored lock
  schema version: a draw locked under schema 6 is run by
  `WallopCore.Entropy.V6Execution`; any other draw is cancelled, untouched.

  The job carries only the draw id. It never chooses a value: the
  execution reads the stored reading or window, or falls back by rule.

  A draw is never marked failed once its drand round is published. Two
  layers keep that true, described in `WallopCore.Entropy.V6Execution`: the
  executor has no path to `mark_failed` (it retries and, out of attempts,
  leaves a discarded job for the re-drive; it waits; or, for stored state
  no retry can change, it cancels, and the cancelled job keeps the re-drive
  away), and the draws guard refuses `failed`
  once the database clock is at or past the fetch deadline F (by tag),
  before pub(R).

  Unique on `draw_id` among live jobs only (Oban's `:incomplete` group:
  available, scheduled, executing, retryable, suspended), so a cancelled or
  discarded job can be inserted again by the re-drive.
  """
  use Oban.Worker,
    # Its own queue, apart from the forecast EntropyWorker's :entropy, so a
    # burst of v6 executions never delays a forecast draw.
    queue: :v6_execution,
    max_attempts: 10,
    unique: [period: :infinity, keys: [:draw_id], states: :incomplete]

  alias WallopCore.Entropy.V6Execution

  # Ends before Lifeline rescues at 2 minutes, as EntropyWorker does.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(90)

  # The longest this worker ever puts a live job off once its draw is due
  # (pub(R)): its retry backoff cap. Its snoozes are shorter: before F or
  # pub(R) it snoozes to pub(R) + 1 s at most, and a "not yet" from the
  # database waits for F or pub(R) plus 2 s (at least 5 s). The re-drive
  # relies on this bound (`StuckDrawRedriver`).
  @max_backoff_seconds 120

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(15 * attempt, @max_backoff_seconds)

  @doc "The longest delay this worker puts on a live job of a draw that is due."
  @spec max_delay_seconds() :: pos_integer()
  def max_delay_seconds, do: @max_backoff_seconds

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"draw_id" => id}, attempt: attempt, max_attempts: max}) do
    case Ash.get(WallopCore.Resources.Draw, id, domain: WallopCore.Domain, authorize?: false) do
      {:ok, %{status: status}} when status in [:completed, :failed, :expired] -> :ok
      {:ok, %{lock_schema_version: "6"} = draw} -> V6Execution.run(draw, attempt, max)
      {:ok, _forecast_draw} -> {:cancel, "not an observation-weather draw"}
      {:error, error} -> if not_found?(error), do: :ok, else: {:error, error}
    end
  end

  defp not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp not_found?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &not_found?/1)
  defp not_found?(_error), do: false
end
