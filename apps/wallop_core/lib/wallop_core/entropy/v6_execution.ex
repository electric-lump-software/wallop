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

  ## A draw is never marked failed once its drand round is published

  The worker only fetches drand after pub(R). From then on the outcome is
  knowable, so stopping the draw by choice would be a selective abort. Two
  layers keep this true:

    1. **This module.** It never marks a draw failed: there is no path from
       here to `mark_failed`. Every outcome after pub(R) is one of:
       * success;
       * a retry (`{:error, _}`) for a transient drand failure or a failed
         execution, which rolls back as one unit; when the job runs out of
         attempts Oban discards it and the draw stays where it is;
       * a refusal: drand still unavailable on the job's last attempt, an
         unrecoverable drand error, or stored state that retrying can't
         change (`WallopCore.Errors.V6ExecRefused`: an unknown pair, an
         entry hash mismatch, the receipt builder rejecting stored state, a
         `fair_pick_version` mismatch). It emits
         `[:wallop_core, :v6, :exec_refused]` naming the cause and cancels
         the job; the re-drive cron brings the draw back;
       * a wait (`WallopCore.Errors.V6NotYet`, for example the app clock
         behind the database's), which snoozes with nothing written.
    2. **The database** (not yet in place: it comes with the execution
       receipt guard). The draws guard will refuse moving an
       observation-weather draw to `failed` once the database clock is at or
       past pub(R), whatever path tries it. Failing before pub(R) stays
       allowed: that is a visible abort before anything is knowable.

  Telemetry: `[:wallop_core, :v6, :executed]` (`%{station, fallback?}`),
  `[:wallop_core, :v6, :execute_error]` (`%{draw_id}`) and
  `[:wallop_core, :v6, :exec_refused]` (`%{draw_id, reason}`).
  """
  require Logger

  alias WallopCore.Entropy.{DrandClient, EntropyWorker, V6Rules}

  # The wait after a post-fetch V6NotYet is measured on this node's clock,
  # the clock execute_v6 checks executed_at on, plus a margin, and never
  # shorter than the floor: a lagging app clock can't cause a tight loop.
  @not_yet_margin_seconds 2
  @not_yet_floor_seconds 5
  alias WallopCore.Errors.{V6ExecRefused, V6NotYet}
  alias WallopCore.Log
  alias WallopCore.Weather.Observations

  @spec run(map(), pos_integer(), pos_integer()) ::
          :ok | {:snooze, pos_integer()} | {:cancel, String.t()} | {:error, term()}
  def run(draw, attempt, max_attempts) do
    case V6Rules.rules(draw) do
      {:ok, rules} ->
        run(rules, draw, attempt, max_attempts)

      :error ->
        refuse(
          draw,
          V6Rules.unknown_pair_message(draw.lock_schema_version, draw.entropy_composition)
        )
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

  defp wait(until, now), do: max(DateTime.diff(until, now) + 1, 1)

  @doc false
  # Seconds to wait after execute_v6 said "not yet" for `retry_at`.
  @spec not_yet_wait(DateTime.t(), DateTime.t()) :: pos_integer()
  def not_yet_wait(retry_at, now),
    do: max(DateTime.diff(retry_at, now) + @not_yet_margin_seconds, @not_yet_floor_seconds)

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
        {:snooze, not_yet_wait(not_yet.retry_at, DateTime.utc_now())}

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

  # Only after pub(R): never fails the draw. A transient failure retries;
  # an unrecoverable one, or one on the last attempt, is a refusal.
  defp drand_failed(draw, reason, attempt, max_attempts) do
    cond do
      match?({:unexpected_status, s} when s in [401, 403], reason) or
          reason == :invalid_response ->
        refuse(draw, "drand unrecoverable error (#{drand_error(reason)})")

      attempt >= max_attempts ->
        refuse(draw, "drand unavailable after #{attempt} attempts (#{drand_error(reason)})")

      true ->
        Logger.warning(
          "V6Execution: drand failed for draw #{Log.redact_id(draw.id)}: #{drand_error(reason)}"
        )

        {:error, "drand unavailable, will retry"}
    end
  end

  defp drand_error({:unexpected_status, status}), do: "HTTP #{status}"
  defp drand_error({:all_relays_failed, _}), do: "all relays failed"
  defp drand_error(reason) when is_atom(reason), do: Atom.to_string(reason)

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

      {:error, error} ->
        Logger.warning(
          "V6Execution: draw #{Log.redact_id(draw.id)} could not move to pending_entropy: " <>
            error_class(error)
        )

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
