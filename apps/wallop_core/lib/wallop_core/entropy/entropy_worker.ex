defmodule WallopCore.Entropy.EntropyWorker do
  @moduledoc """
  Oban worker that collects entropy sources for a draw.

  Two-phase retry:
  - Phase 1 (attempts 1-5): Try both drand and weather. Retry on failure.
  - Phase 2 (attempts 6-10): If drand succeeds but weather doesn't,
    proceed with drand-only seed computation.

  Fails fast on permanent errors (auth failures, invalid responses).
  """
  use Oban.Worker,
    queue: :entropy,
    max_attempts: 10,
    unique: [period: :infinity, keys: [:draw_id]]

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias WallopCore.Entropy.{DrandClient, WeatherClient, WebhookWorker}

  # After this many attempts, fall back to drand-only if weather is unavailable
  @weather_attempt_threshold 5

  # Middle Wallop coordinates
  @latitude 51.1486
  @longitude -1.5714

  @impl true
  def backoff(%Oban.Job{attempt: attempt}) do
    case attempt do
      1 -> 15
      2 -> 30
      3 -> 45
      4 -> 60
      5 -> 90
      _ -> 120
    end
  end

  @impl true
  def perform(%Oban.Job{
        args: %{"draw_id" => draw_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case load_draw(draw_id) do
      {:ok, draw} ->
        process_draw(draw, attempt, max_attempts)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_draw(%{status: status}, _attempt, _max_attempts)
       when status in [:completed, :failed],
       do: :ok

  defp process_draw(draw, attempt, max_attempts) do
    attempt_execution(draw, attempt, max_attempts)
  end

  defp attempt_execution(draw, attempt, max_attempts) do
    Tracer.with_span "entropy_worker.attempt",
      attributes: %{
        "draw.id" => draw.id,
        "draw.status" => to_string(draw.status),
        "draw.weather_time" => DateTime.to_iso8601(draw.weather_time),
        "draw.drand_round" => draw.drand_round,
        "job.attempt" => attempt,
        "job.max_attempts" => max_attempts
      } do
      draw = maybe_transition_to_pending(draw)

      ctx = OpenTelemetry.Ctx.get_current()

      drand_task =
        Task.async(fn ->
          OpenTelemetry.Ctx.attach(ctx)

          Tracer.with_span "entropy.fetch_drand",
            attributes: %{"drand.chain" => draw.drand_chain, "drand.round" => draw.drand_round} do
            DrandClient.fetch_with_failover(draw.drand_chain, draw.drand_round)
          end
        end)

      weather_task =
        Task.async(fn ->
          OpenTelemetry.Ctx.attach(ctx)

          Tracer.with_span "entropy.fetch_weather",
            attributes: %{"weather.lat" => @latitude, "weather.lon" => @longitude} do
            WeatherClient.fetch(@latitude, @longitude, draw.weather_time)
          end
        end)

      drand_result = Task.await(drand_task, 30_000)
      weather_result = Task.await(weather_task, 30_000)

      broadcast_entropy_status(draw, attempt, max_attempts, drand_result, weather_result)
      handle_results(draw, drand_result, weather_result, attempt, max_attempts)
    end
  end

  # Both sources succeeded
  defp handle_results(draw, {:ok, drand}, {:ok, weather}, _attempt, _max_attempts) do
    Tracer.set_attributes(%{
      "entropy.drand_round" => drand.round,
      "entropy.weather_value" => weather.value,
      "entropy.weather_observation_time" => DateTime.to_iso8601(weather.observation_time)
    })

    execute_draw(draw, drand, weather)
  end

  # At least one source failed
  defp handle_results(draw, drand_result, weather_result, attempt, max_attempts) do
    drand_err = error_from(drand_result)
    weather_err = error_from(weather_result)

    permanent = find_permanent_error(drand_err, weather_err)

    cond do
      # Permanent error — fail immediately
      permanent != nil ->
        Tracer.set_attributes(%{
          "error" => true,
          "error.type" => "permanent",
          "error.message" => permanent
        })

        fail_draw_with_reason(draw, permanent)

      # Phase 2: drand OK, weather failed, past threshold — drand-only fallback
      drand_err == nil and weather_err != nil and attempt >= @weather_attempt_threshold ->
        {:ok, drand} = drand_result

        Tracer.set_attributes(%{
          "entropy.drand_round" => drand.round,
          "entropy.fallback" => "drand_only",
          "entropy.weather_error" => inspect(weather_err)
        })

        Logger.info(
          "EntropyWorker: falling back to drand-only for draw #{draw.id} " <>
            "(weather failed after #{attempt} attempts: #{inspect(weather_err)})"
        )

        execute_drand_only(draw, drand, inspect(weather_err))

      # Final attempt — fail the draw
      attempt >= max_attempts ->
        reason =
          cond do
            drand_err != nil ->
              "drand unavailable after #{attempt} attempts: #{inspect(drand_err)}"

            weather_err != nil ->
              "weather unavailable after #{attempt} attempts: #{inspect(weather_err)}"

            true ->
              "entropy sources unavailable after #{attempt} attempts"
          end

        fail_draw_with_reason(draw, reason)

      # Phase 1: retry
      true ->
        log_transient_errors(draw, drand_err, weather_err)

        Tracer.set_attributes(%{
          "error" => true,
          "error.type" => "transient",
          "entropy.drand_error" => inspect(drand_err),
          "entropy.weather_error" => inspect(weather_err)
        })

        {:error, "entropy sources unavailable, will retry"}
    end
  end

  defp error_from({:ok, _}), do: nil
  defp error_from({:error, reason}), do: reason

  defp find_permanent_error(drand_err, weather_err) do
    cond do
      permanent_error?(drand_err) -> "drand: #{format_permanent(drand_err)}"
      permanent_error?(weather_err) -> "weather: #{format_permanent(weather_err)}"
      true -> nil
    end
  end

  defp permanent_error?({:unexpected_status, status}) when status in [401, 403], do: true
  defp permanent_error?(:invalid_response), do: true
  defp permanent_error?(_), do: false

  defp format_permanent({:unexpected_status, status}), do: "HTTP #{status} — check credentials"
  defp format_permanent(:invalid_response), do: "invalid response from API"
  defp format_permanent(other), do: inspect(other)

  defp log_transient_errors(draw, drand_err, weather_err) do
    case {drand_err, weather_err} do
      {err, nil} when err != nil ->
        Logger.warning("EntropyWorker: drand failed for draw #{draw.id}: #{inspect(err)}")

      {nil, err} when err != nil ->
        Logger.warning("EntropyWorker: weather failed for draw #{draw.id}: #{inspect(err)}")

      {d_err, w_err} when d_err != nil and w_err != nil ->
        Logger.warning(
          "EntropyWorker: both sources failed for draw #{draw.id}. " <>
            "drand=#{inspect(d_err)}, weather=#{inspect(w_err)}"
        )

      _ ->
        :ok
    end
  end

  defp execute_draw(draw, drand, weather) do
    Tracer.with_span "entropy_worker.execute_draw", attributes: %{"draw.id" => draw.id} do
      draw
      |> Ash.Changeset.for_update(:execute_with_entropy, %{
        drand_randomness: drand.randomness,
        drand_signature: drand.signature,
        drand_response: drand.response,
        weather_value: weather.value,
        weather_raw: weather.raw,
        weather_observation_time: weather.observation_time
      })
      |> Ash.update(domain: WallopCore.Domain, authorize?: false)
      |> case do
        {:ok, completed_draw} ->
          broadcast_update(completed_draw)
          maybe_enqueue_webhook(completed_draw)
          :ok

        {:error, reason} ->
          Tracer.set_attributes(%{"error" => true, "error.message" => inspect(reason)})

          Logger.warning(
            "EntropyWorker: execution failed for draw #{draw.id}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp execute_drand_only(draw, drand, weather_error_reason) do
    Tracer.with_span "entropy_worker.execute_drand_only", attributes: %{"draw.id" => draw.id} do
      draw
      |> Ash.Changeset.for_update(:execute_drand_only, %{
        drand_randomness: drand.randomness,
        drand_signature: drand.signature,
        drand_response: drand.response,
        weather_fallback_reason: weather_error_reason
      })
      |> Ash.update(domain: WallopCore.Domain, authorize?: false)
      |> case do
        {:ok, completed_draw} ->
          broadcast_update(completed_draw)
          maybe_enqueue_webhook(completed_draw)
          :ok

        {:error, reason} ->
          Tracer.set_attributes(%{"error" => true, "error.message" => inspect(reason)})

          Logger.warning(
            "EntropyWorker: drand-only execution failed for draw #{draw.id}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp broadcast_entropy_status(draw, attempt, max_attempts, drand_result, weather_result) do
    phase =
      if attempt >= @weather_attempt_threshold and match?({:error, _}, weather_result) and
           match?({:ok, _}, drand_result) do
        :drand_only_fallback
      else
        :collecting
      end

    Phoenix.PubSub.broadcast(
      WallopCore.PubSub,
      "draw:#{draw.id}",
      {:entropy_status,
       %{
         attempt: attempt,
         max_attempts: max_attempts,
         drand: status_from(drand_result),
         weather: status_from(weather_result),
         phase: phase
       }}
    )
  end

  defp status_from({:ok, _}), do: :ok
  defp status_from({:error, reason}), do: {:error, reason}

  defp load_draw(draw_id) do
    case Ash.get(WallopCore.Resources.Draw, draw_id,
           domain: WallopCore.Domain,
           authorize?: false
         ) do
      {:ok, draw} -> {:ok, draw}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_transition_to_pending(%{status: :awaiting_entropy} = draw) do
    case draw
         |> Ash.Changeset.for_update(:transition_to_pending, %{})
         |> Ash.update(domain: WallopCore.Domain, authorize?: false) do
      {:ok, updated} ->
        broadcast_update(updated)
        updated

      {:error, _} ->
        draw
    end
  end

  defp maybe_transition_to_pending(draw), do: draw

  defp fail_draw_with_reason(draw, reason) do
    draw = maybe_transition_to_pending(draw)

    draw
    |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: reason})
    |> Ash.update(domain: WallopCore.Domain, authorize?: false)
    |> case do
      {:ok, failed_draw} ->
        broadcast_update(failed_draw)
        maybe_enqueue_webhook(failed_draw)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast_update(draw) do
    Phoenix.PubSub.broadcast(WallopCore.PubSub, "draw:#{draw.id}", {:draw_updated, draw})
  end

  defp maybe_enqueue_webhook(%{callback_url: nil}), do: :ok

  defp maybe_enqueue_webhook(%{callback_url: url, id: draw_id, api_key_id: api_key_id})
       when is_binary(url) do
    %{draw_id: draw_id, api_key_id: api_key_id}
    |> WebhookWorker.new()
    |> Oban.insert()

    :ok
  end
end
