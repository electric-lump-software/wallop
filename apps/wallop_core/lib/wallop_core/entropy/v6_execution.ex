defmodule WallopCore.Entropy.V6Execution do
  @moduledoc """
  Runs a lock schema 6 draw (Met Office Land Observations or GB grid
  frequency) once its fetch window has closed and its drand round has
  published. Run by `ObservationDrawWorker`. A draw is executed under the rules of the
  (lock_schema_version, entropy_composition) pair it was locked with
  (`WallopCore.Entropy.V6Rules`), whatever the operator's flag says now.

  The executor has no discretion. It passes only the drand beacon to
  `:execute_v6`, which reads the stored reading itself under the draw's row
  lock and falls back to drand alone only when nothing is stored and the
  database clock is past the fetch deadline (for grid frequency, past
  F + M).

  ## A draw is never marked failed once its drand round is published

  The worker only fetches drand after pub(R). From then on the outcome is
  knowable, so stopping the draw by choice would be a selective abort. Two
  layers keep this true:

    1. **This module.** It never marks a draw failed: there is no path from
       here to `mark_failed`. Every outcome after pub(R) is one of:
       * success;
       * a retry (`{:error, _}`) for a transient drand failure (one relay's
         invalid response, malformed body, 404, 401 or 403 moves on to the
         next relay, as does a relay that misses its 10 s deadline or
         sends a beacon whose BLS signature doesn't verify; every
         relay failing, and the fetch raising or exiting, are transient)
         or a failed
         execution, which rolls back as one unit; when the job runs out of
         attempts Oban discards it and the draw stays where it is. drand
         still unavailable on the last attempt is reported as
         `[:wallop_core, :v6, :drand_exhausted]` and is still an error, not
         a cancel: the discarded job is re-inserted by the re-drive cron
         once the draw is stuck, so an outage needs no hand;
       * a refusal: stored state that retrying can't change (`WallopCore.Errors.V6ExecRefused`: an unknown pair, an
         entry hash mismatch, the receipt builder rejecting stored state, a
         `fair_pick_version` mismatch). It emits
         `[:wallop_core, :v6, :exec_refused]` naming the cause and cancels
         the job. The cancelled job marks the refusal: the re-drive leaves
         the draw alone while it remains, and re-running it after a fix is
         a manual re-insert;
       * a wait (`WallopCore.Errors.V6NotYet`, for example the app clock
         behind the database's), which snoozes with nothing written.
    2. **The database.** The draws guard refuses moving a lock schema 6
       draw to `failed` once the database clock is at or past its fetch
       deadline F (chosen by tag; a minute or more before pub(R) for Land
       Obs, M or more for grid frequency), from any status and whatever
       path tries it, on the statement clock and again at commit. Failing before F stays allowed:
       that is a visible abort before anything is knowable.

  The stored `drand_response` is the beacon re-encoded as
  `{"randomness", "round", "signature"}`, never the relay's own bytes, so
  nothing a relay adds is stored or served.

  Each successful fetch also compares the database clock with the
  publication time of drand's latest round. The guards above trust that
  clock, so a skew over 5 s is reported.

  Telemetry: `[:wallop_core, :v6, :executed]`
  (`%{entropy_composition, station, fallback?, source}`, from
  `WallopCore.Entropy.V6Rules.report_meta/2`; `source` is `:weather`,
  `:frequency` or `:drand_only`, the input that fed the seed, so a
  weather-tag draw that ended on drand alone is visible per draw),
  `[:wallop_core, :v6, :execute_error]` (`%{draw_id}`),
  `[:wallop_core, :v6, :exec_refused]` (`%{draw_id, reason}`),
  `[:wallop_core, :v6, :drand_exhausted]` (`%{draw_id, reason}`) and
  `[:wallop_core, :v6, :clock_skew]` (measurements `%{skew_ms}`: the
  database clock minus pub(latest round), metadata `%{draw_id, round}`).
  """
  require Logger

  alias WallopCore.DbClock
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{DrandClient, V6Rules}

  # The wait after a post-fetch V6NotYet is measured on this node's clock,
  # the clock execute_v6 checks executed_at on, plus a margin, and never
  # shorter than the floor: a lagging app clock can't cause a tight loop.
  @not_yet_margin_seconds 2
  @not_yet_floor_seconds 5
  # The clock skew check: report beyond this, and never wait longer for it.
  @skew_alarm_ms 5_000
  @skew_check_timeout_ms 3_000
  alias WallopCore.Errors.{V6ExecRefused, V6NotYet}
  alias WallopCore.Log

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
    now = DbClock.now()
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
    # One relay's invalid response must not end the attempt: try the next.
    # If every relay fails, that is transient like any other outage.
    case fetch_drand(draw) do
      {:ok, drand} ->
        check_clock_skew(draw)
        execute(draw, drand)

      {:error, reason} ->
        drand_failed(draw, reason, attempt, max_attempts)
    end
  end

  # A fetch that raises or exits is a transient drand failure like any other.
  # The beacon's BLS signature is checked against quicknet's key: a relay
  # that forges a round is just a relay with an invalid response.
  defp fetch_drand(draw) do
    DrandClient.fetch_with_failover(draw.drand_chain, draw.drand_round,
      on_invalid: :next,
      verify_bls: true
    )
  rescue
    e -> {:error, {:raised, e.__struct__}}
  catch
    :exit, _ -> {:error, :fetch_exited}
  end

  # Telemetry only: never changes the outcome, never waits long.
  defp check_clock_skew(draw) do
    task =
      Task.async(fn ->
        try do
          DrandClient.current_round(draw.drand_chain)
        rescue
          _ -> :error
        catch
          :exit, _ -> :error
        end
      end)

    with {:ok, {:ok, latest}} when is_integer(latest) and latest >= 1 <-
           Task.yield(task, @skew_check_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      skew_ms = DateTime.diff(DbClock.now(), Quicknet.pub_time(latest), :millisecond)

      if abs(skew_ms) > @skew_alarm_ms do
        Logger.warning(
          "V6Execution: database clock is #{skew_ms} ms from drand round #{latest}'s publication"
        )

        :telemetry.execute([:wallop_core, :v6, :clock_skew], %{skew_ms: skew_ms}, %{
          draw_id: draw.id,
          round: latest
        })
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # The beacon itself, re-encoded: the relay's own bytes (and anything it
  # added to them) are never stored.
  defp beacon_json(drand) do
    Jason.encode!(%{
      "randomness" => drand.randomness,
      "round" => drand.round,
      "signature" => drand.signature
    })
  end

  # drand is known from here on: never mark the draw failed.
  defp execute(draw, drand) do
    draw
    |> Ash.Changeset.for_update(:execute_v6, %{
      drand_randomness: drand.randomness,
      drand_signature: drand.signature,
      drand_response: beacon_json(drand)
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
    case settle_after_error(draw.id, :not_settled) do
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
      "V6Execution: draw #{Log.redact_id(draw.id)} refused on its stored state: #{message}; " <>
        "it is not re-driven: re-insert its job by hand after a fix"
    )

    :telemetry.execute([:wallop_core, :v6, :exec_refused], %{count: 1}, %{
      draw_id: draw.id,
      reason: message
    })

    {:cancel, "execution refused: #{message}"}
  end

  defp report(draw) do
    :telemetry.execute(
      [:wallop_core, :v6, :executed],
      %{count: 1},
      V6Rules.report_meta(V6Rules.rules!(draw), draw)
    )
  end

  # Only after pub(R): never fails the draw, and never cancels the job. A
  # drand failure is transient however long it lasts: on the last attempt
  # it is reported and returned as an error, so Oban discards the job and
  # the re-drive inserts a new one once the draw is stuck.
  defp drand_failed(draw, reason, attempt, max_attempts) do
    if attempt >= max_attempts do
      message = "drand unavailable after #{attempt} attempts (#{drand_error(reason)})"

      Logger.error(
        "V6Execution: draw #{Log.redact_id(draw.id)}: #{message}; left for the re-drive"
      )

      :telemetry.execute([:wallop_core, :v6, :drand_exhausted], %{count: 1}, %{
        draw_id: draw.id,
        reason: message
      })

      {:error, message}
    else
      Logger.warning(
        "V6Execution: drand failed for draw #{Log.redact_id(draw.id)}: #{drand_error(reason)}"
      )

      {:error, "drand unavailable, will retry"}
    end
  end

  defp drand_error({:unexpected_status, status}), do: "HTTP #{status}"
  defp drand_error({:all_relays_failed, _}), do: "all relays failed"
  defp drand_error({:raised, module}), do: "fetch raised #{inspect(module)}"
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

  # The draw finished while this attempt was running (another attempt, or a
  # Lifeline rescue). Its outcome and webhook are already committed, so this
  # attempt succeeded at nothing and must not retry or fail the draw.
  # `:expired` is listed for completeness: only open draws expire, so a draw
  # this module runs can't become expired.
  @doc false
  @spec settle_after_error(String.t(), term()) :: :ok | {:error, term()}
  def settle_after_error(draw_id, reason) do
    case Ash.get(WallopCore.Resources.Draw, draw_id,
           domain: WallopCore.Domain,
           authorize?: false
         ) do
      {:ok, %{status: status}} when status in [:completed, :failed, :expired] ->
        Logger.info(
          "V6Execution: draw #{Log.redact_id(draw_id)} already #{status}; nothing to do"
        )

        :ok

      _ ->
        {:error, reason}
    end
  end
end
