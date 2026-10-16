defmodule WallopCore.Entropy.V6Execution do
  @moduledoc """
  Runs an observation-weather draw once its fetch window has closed and its
  drand round has published. Shared by `ObservationDrawWorker` and
  `EntropyWorker`, so a draw is executed under the rules of the
  (lock_schema_version, entropy_composition) pair it was locked with
  (`WallopCore.Entropy.V6Rules`), whatever the operator's flag says now.

  The executor has no discretion. It passes only the drand beacon to
  `:execute_v6`, which reads the stored reading itself under the draw's row
  lock and falls back to drand alone only when nothing is stored and the
  database clock is past the fetch deadline.

  ## A draw is never marked failed once drand has been fetched

  Two layers keep this true:

    1. **This module.** Only a failure *before* drand is fetched may fail
       the draw: an unrecoverable drand error, or drand still unavailable on
       the job's last attempt. Once drand has been fetched it never calls
       `mark_failed`. A failed execution is retried; when the job runs out of
       attempts Oban discards it and the draw stays in `pending_entropy`
       for the re-drive cron to pick up. A refusal that retrying can't change
       (`WallopCore.Errors.V6ExecRefused`: an unknown pair, the receipt
       builder rejecting stored state, a `fair_pick_version` mismatch) emits
       `[:wallop_core, :v6, :exec_refused]` and cancels the job at once,
       leaving the draw as it is for the re-drive and an alert. A refusal
       because the draw isn't due yet (`WallopCore.Errors.V6NotYet`, for
       example the app clock behind the database's) snoozes, with nothing
       written.
    2. **The database.** The draws guard refuses moving an observation-weather
       draw to `failed` once its drand randomness is stored, whatever path
       tries it. Execution rolls back as one unit, so a refused execution
       never leaves drand randomness stored, and the pre-drand failure above
       stays allowed.

  Telemetry: `[:wallop_core, :v6, :executed]` (`%{station, fallback?}`),
  `[:wallop_core, :v6, :execute_error]` (`%{draw_id}`) and
  `[:wallop_core, :v6, :exec_refused]` (`%{draw_id, reason}`).
  """
  require Logger

  alias WallopCore.Entropy.{DrandClient, EntropyWorker, V6Rules}
  alias WallopCore.Errors.{V6ExecRefused, V6NotYet}
  alias WallopCore.Log
  alias WallopCore.Weather.Observations

  @spec run(map(), pos_integer(), pos_integer()) ::
          :ok | {:snooze, pos_integer()} | {:cancel, String.t()} | {:error, term()}
  def run(draw, attempt, max_attempts) do
    case rules(draw) do
      {:ok, rules} -> run(rules, draw, attempt, max_attempts)
      {:error, message} -> refuse(draw, message)
    end
  end

  defp run(rules, draw, attempt, max_attempts) do
    now = Observations.db_now()
    deadline = V6Rules.fetch_deadline(rules, draw)
    pub = V6Rules.drand_pub_time(rules, draw)

    cond do
      DateTime.compare(now, deadline) != :gt -> {:snooze, wait(deadline, now)}
      DateTime.compare(now, pub) == :lt -> {:snooze, wait(pub, now)}
      true -> draw |> to_pending() |> fetch_and_execute(attempt, max_attempts)
    end
  end

  defp rules(draw) do
    {:ok, V6Rules.rules!(draw)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp wait(until, now), do: max(DateTime.diff(until, now) + 1, 1)

  defp fetch_and_execute(draw, attempt, max_attempts) do
    case DrandClient.fetch_with_failover(draw.drand_chain, draw.drand_round) do
      {:ok, drand} -> execute(draw, drand)
      {:error, reason} -> drand_failed(draw, reason, attempt, max_attempts)
    end
  end

  # drand is known from here on: never mark the draw failed.
  defp execute(draw, drand) do
    draw
    |> Ash.Changeset.for_update(:execute_v6, %{
      drand_randomness: drand.randomness,
      drand_signature: drand.signature,
      drand_response: drand.response
    })
    |> Ash.update(domain: WallopCore.Domain, authorize?: false)
    |> case do
      {:ok, done} ->
        report(done)
        :ok

      {:error, error} ->
        after_error(draw, error)
    end
  rescue
    e -> execute_error(draw, e)
  end

  defp after_error(draw, error) do
    cond do
      refused = find_error(error, V6ExecRefused) ->
        refuse(draw, refused.message)

      not_yet = find_error(error, V6NotYet) ->
        {:snooze, wait(not_yet.retry_at, Observations.db_now())}

      true ->
        execute_error(draw, error)
    end
  end

  defp execute_error(draw, error) do
    # Another attempt (or a Lifeline rescue) may have finished the draw.
    case EntropyWorker.settle_after_error(draw.id, :not_settled) do
      :ok ->
        :ok

      {:error, :not_settled} ->
        Logger.error(
          "V6Execution: draw #{Log.redact_id(draw.id)} could not execute after drand was " <>
            "fetched; will retry: #{error_class(error)}"
        )

        :telemetry.execute([:wallop_core, :v6, :execute_error], %{count: 1}, %{draw_id: draw.id})
        {:error, "execution failed after drand was fetched; will retry"}
    end
  end

  defp refuse(draw, message) do
    Logger.error(
      "V6Execution: draw #{Log.redact_id(draw.id)} refused, left for the re-drive: #{message}"
    )

    :telemetry.execute([:wallop_core, :v6, :exec_refused], %{count: 1}, %{
      draw_id: draw.id,
      reason: message
    })

    {:cancel, "execution refused: #{message}"}
  end

  defp report(draw) do
    station = with %{station: s} <- Observations.for_draw(draw), do: s

    :telemetry.execute([:wallop_core, :v6, :executed], %{count: 1}, %{
      station: station,
      fallback?: is_nil(station)
    })
  end

  defp drand_failed(draw, reason, attempt, max_attempts) do
    cond do
      match?({:unexpected_status, s} when s in [401, 403], reason) or
          reason == :invalid_response ->
        EntropyWorker.fail_draw_with_reason(draw, "drand: unrecoverable error", reason)

      attempt >= max_attempts ->
        EntropyWorker.fail_draw_with_reason(
          draw,
          "drand unavailable after #{attempt} attempts",
          reason
        )

      true ->
        Logger.warning(
          "V6Execution: drand failed for draw #{Log.redact_id(draw.id)}: #{inspect(reason)}"
        )

        {:error, "drand unavailable, will retry"}
    end
  end

  defp to_pending(%{status: :awaiting_entropy} = draw) do
    case draw
         |> Ash.Changeset.for_update(:transition_to_pending, %{})
         |> Ash.update(domain: WallopCore.Domain, authorize?: false) do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(
          WallopCore.PubSub,
          "draw:#{updated.id}",
          {:draw_updated, updated}
        )

        updated

      {:error, _} ->
        draw
    end
  end

  defp to_pending(draw), do: draw

  # The first error of `module` anywhere in an Ash error class, or nil.
  defp find_error(%{__struct__: module} = error, module), do: error

  defp find_error(%{errors: errors}, module) when is_list(errors),
    do: Enum.find_value(errors, &find_error(&1, module))

  defp find_error(_error, _module), do: nil

  defp error_class(%{__struct__: module}), do: inspect(module)
end
