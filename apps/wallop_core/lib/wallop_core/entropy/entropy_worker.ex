defmodule WallopCore.Entropy.EntropyWorker do
  @moduledoc """
  Oban worker that collects entropy sources for a draw.

  Scheduled to run at the draw's weather_time. Fetches drand randomness
  and weather data, computes the seed, and executes the draw.

  Retries with exponential backoff up to 20 attempts. If entropy cannot be
  collected within 24 hours of job creation, the draw is marked as failed.
  """
  use Oban.Worker,
    queue: :entropy,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:draw_id]]

  require Logger

  alias WallopCore.Entropy.{DrandClient, WeatherClient, WebhookWorker}

  @failure_timeout_hours 24

  # Middle Wallop coordinates
  @latitude 51.1486
  @longitude -1.5714

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
    draw = maybe_transition_to_pending(draw)

    drand_task =
      Task.async(fn ->
        DrandClient.fetch(draw.drand_chain, draw.drand_round)
      end)

    weather_task =
      Task.async(fn ->
        WeatherClient.fetch(@latitude, @longitude)
      end)

    drand_result = Task.await(drand_task, 30_000)
    weather_result = Task.await(weather_task, 30_000)

    case {drand_result, weather_result} do
      {{:ok, drand}, {:ok, weather}} ->
        execute_draw(draw, drand, weather)

      {{:error, drand_err}, {:error, weather_err}} ->
        Logger.warning(
          "EntropyWorker: both sources failed for draw #{draw.id}. " <>
            "drand=#{inspect(drand_err)}, weather=#{inspect(weather_err)}"
        )

        {:snooze, compute_backoff(draw)}

      {{:error, drand_err}, _} ->
        Logger.warning("EntropyWorker: drand failed for draw #{draw.id}: #{inspect(drand_err)}")

        {:snooze, compute_backoff(draw)}

      {_, {:error, weather_err}} ->
        Logger.warning(
          "EntropyWorker: weather failed for draw #{draw.id}: #{inspect(weather_err)}"
        )

        {:snooze, compute_backoff(draw)}
    end
  end

  defp execute_draw(draw, drand, weather) do
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
        Logger.warning("EntropyWorker: execution failed for draw #{draw.id}: #{inspect(reason)}")
        {:error, reason}
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
    draw = maybe_transition_to_pending(draw)

    draw
    |> Ash.Changeset.for_update(:mark_failed, %{
      failure_reason: "entropy collection timed out after #{@failure_timeout_hours} hours"
    })
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

  defp compute_backoff(draw) do
    # Exponential backoff based on how long since the draw was created.
    # Start at 30s, double each time, cap at 15 minutes.
    elapsed = DateTime.diff(DateTime.utc_now(), draw.inserted_at, :second)

    interval =
      cond do
        elapsed < 120 -> 30
        elapsed < 600 -> 60
        elapsed < 1800 -> 120
        elapsed < 3600 -> 300
        true -> 900
      end

    interval
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
