defmodule WallopCore.Entropy.EntropyWorker do
  @moduledoc """
  Oban worker that collects entropy sources for a draw.

  Scheduled to run at the draw's weather_time. Fetches drand randomness
  and weather data, computes the seed, and executes the draw.

  Uses Oban's built-in attempt tracking with exponential backoff.
  Fails fast on permanent errors (auth failures, invalid responses).
  If entropy cannot be collected within 2 hours of job creation, the
  draw is marked as failed.
  """
  use Oban.Worker,
    queue: :entropy,
    max_attempts: 10,
    unique: [period: :infinity, keys: [:draw_id]]

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias WallopCore.Entropy.{DrandClient, WeatherClient, WebhookWorker}

  @failure_timeout_hours 2

  # Middle Wallop coordinates
  @latitude 51.1486
  @longitude -1.5714

  @impl true
  def backoff(%Oban.Job{attempt: attempt}) do
    # Exponential backoff: ~30s, ~60s, ~2m, ~4m, ~8m, capped at 15m
    min(trunc(:math.pow(2, attempt) * 15), 900)
  end

  @impl true
  def perform(%Oban.Job{args: %{"draw_id" => draw_id}, inserted_at: inserted_at}) do
    case load_draw(draw_id) do
      {:ok, draw} ->
        process_draw(draw, inserted_at)

      {:error, :not_found} ->
        # Draw was deleted, nothing to do
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_draw(draw, job_inserted_at) do
    cond do
      draw.status in [:completed, :failed] ->
        :ok

      past_failure_timeout?(job_inserted_at) ->
        fail_draw(draw)

      true ->
        attempt_execution(draw)
    end
  end

  defp attempt_execution(draw) do
    Tracer.with_span "entropy_worker.attempt", attributes: %{"draw.id" => draw.id} do
      draw = maybe_transition_to_pending(draw)

      drand_task =
        Task.async(fn ->
          Tracer.with_span "entropy.fetch_drand",
            attributes: %{"drand.chain" => draw.drand_chain, "drand.round" => draw.drand_round} do
            DrandClient.fetch(draw.drand_chain, draw.drand_round)
          end
        end)

      weather_task =
        Task.async(fn ->
          Tracer.with_span "entropy.fetch_weather",
            attributes: %{"weather.lat" => @latitude, "weather.lon" => @longitude} do
            WeatherClient.fetch(@latitude, @longitude, draw.weather_time)
          end
        end)

      drand_result = Task.await(drand_task, 30_000)
      weather_result = Task.await(weather_task, 30_000)

      handle_results(draw, drand_result, weather_result)
    end
  end

  defp handle_results(draw, {:ok, drand}, {:ok, weather}) do
    execute_draw(draw, drand, weather)
  end

  defp handle_results(draw, drand_result, weather_result) do
    drand_err = error_from(drand_result)
    weather_err = error_from(weather_result)

    # Check for permanent errors — fail immediately, don't retry
    permanent = find_permanent_error(drand_err, weather_err)

    if permanent do
      Tracer.set_attributes(%{
        "error" => true,
        "error.type" => "permanent",
        "error.message" => permanent
      })

      fail_draw_with_reason(draw, permanent)
    else
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
      permanent_error?(drand_err) ->
        "drand: #{format_permanent(drand_err)}"

      permanent_error?(weather_err) ->
        "weather: #{format_permanent(weather_err)}"

      true ->
        nil
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

  defp fail_draw(draw) do
    fail_draw_with_reason(
      draw,
      "entropy collection timed out after #{@failure_timeout_hours} hours"
    )
  end

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

  defp past_failure_timeout?(inserted_at) do
    cutoff = DateTime.add(inserted_at, @failure_timeout_hours * 3600, :second)
    DateTime.compare(DateTime.utc_now(), cutoff) != :lt
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
