defmodule WallopWeb.Components.DrawTimeline do
  @moduledoc """
  Vertical timeline showing draw stages.

  Renders a daisyUI steps component that reflects the current
  progress of a draw through its lifecycle.
  """
  use WallopWeb, :html

  attr(:draw, :map, required: true)

  def draw_timeline(assigns) do
    assigns = assign(assigns, :stages, build_stages(assigns.draw))

    ~H"""
    <ul class="steps steps-vertical w-full">
      <li :for={{stage, idx} <- Enum.with_index(@stages)} class={step_class(stage.state)} data-content={idx} data-reveal-step={idx}>
        <div class="text-left py-2">
          <div class="font-semibold text-sm">
            {stage.label}
            <span :if={stage[:timestamp]} class="font-normal text-[10px] text-gray-400 ml-1">{stage.timestamp}</span>
          </div>
          <div :if={stage[:countdown_target]} class="text-xs text-[#555] mt-1">
            <div>Entropy available in</div>
            <span
              id="entropy-countdown"
              class="countdown font-mono text-lg"
              phx-hook="Countdown"
              data-target={DateTime.to_iso8601(stage.countdown_target)}
            >
              <span data-hours style="--value:0; --digits:2;" aria-live="polite" aria-label="0">00</span>:
              <span data-minutes style="--value:0; --digits:2;" aria-live="polite" aria-label="0">00</span>:
              <span data-seconds style="--value:0; --digits:2;" aria-live="polite" aria-label="0">00</span>
            </span>
          </div>
          <div :if={stage.detail} class="text-xs text-[#555] mt-0.5" data-reveal-detail={idx}>
            {stage.detail}
          </div>
        </div>
      </li>
    </ul>
    """
  end

  defp build_stages(draw) do
    status = draw.status

    [
      entries_open_stage(draw, status),
      entries_locked_stage(draw, status),
      entropy_declared_stage(draw, status),
      fetching_entropy_stage(draw, status),
      computing_seed_stage(draw, status),
      winners_selected_stage(draw, status)
    ]
  end

  defp entries_open_stage(draw, status) do
    count = draw.entry_count || 0
    ts = draw.stage_timestamps || %{}

    case status do
      :open ->
        %{
          label: "Entries Open",
          detail: "#{count} entries",
          state: :current
        }

      _ ->
        %{
          label: "Entries Open",
          detail: "#{count} entries (closed)",
          state: :done,
          timestamp: format_timestamp(ts["opened_at"], draw.inserted_at)
        }
    end
  end

  defp entries_locked_stage(draw, status) do
    ts = draw.stage_timestamps || %{}

    if status == :open do
      %{label: "Entries Locked", detail: nil, state: :pending}
    else
      count = draw.entry_count || 0
      hash = truncate_hash(draw.entry_hash)

      %{
        label: "Entries Locked",
        detail: "#{count} entries committed, hash: #{hash}",
        state: :done,
        timestamp: format_timestamp(ts["locked_at"])
      }
    end
  end

  defp entropy_declared_stage(draw, status) do
    ts = draw.stage_timestamps || %{}

    if status in [:open, :locked] do
      %{label: "Entropy Declared", detail: nil, state: :pending}
    else
      round_text = if draw.drand_round, do: "drand round ##{draw.drand_round}", else: nil

      weather_text =
        if draw.weather_time,
          do: "weather at #{Calendar.strftime(draw.weather_time, "%H:%M UTC")}",
          else: nil

      detail = [round_text, weather_text] |> Enum.reject(&is_nil/1) |> Enum.join(", ")

      %{
        label: "Entropy Declared",
        detail: if(detail != "", do: detail, else: "sources declared"),
        state: :done,
        timestamp: format_timestamp(ts["entropy_declared_at"])
      }
    end
  end

  defp fetching_entropy_stage(draw, status) do
    case status do
      s when s in [:open, :locked] ->
        %{label: "Fetching Entropy", detail: nil, state: :pending}

      :awaiting_entropy ->
        %{
          label: "Fetching Entropy",
          detail: nil,
          state: :current,
          countdown_target: draw.weather_time
        }

      :pending_entropy ->
        %{
          label: "Fetching Entropy",
          detail: "waiting for drand round and weather observation...",
          state: :current
        }

      :completed ->
        ts = draw.stage_timestamps || %{}

        %{
          label: "Fetching Entropy",
          detail: entropy_detail(draw),
          state: :done,
          timestamp: format_timestamp(ts["executed_at"], draw.executed_at)
        }

      :failed ->
        %{
          label: "Fetching Entropy",
          detail: draw.failure_reason || "failed",
          state: :failed
        }
    end
  end

  defp computing_seed_stage(draw, status) do
    ts = draw.stage_timestamps || %{}

    case status do
      :completed ->
        %{
          label: "Computing Seed",
          detail: "seed: #{truncate_hash(draw.seed)}",
          state: :done,
          timestamp: format_timestamp(ts["executed_at"], draw.executed_at)
        }

      :failed ->
        %{label: "Computing Seed", detail: nil, state: :failed}

      _ ->
        %{label: "Computing Seed", detail: nil, state: :pending}
    end
  end

  defp winners_selected_stage(draw, status) do
    ts = draw.stage_timestamps || %{}

    case status do
      :completed ->
        count = length(draw.results || [])

        %{
          label: "Winners Selected",
          detail: "#{count} winner(s)",
          state: :done,
          timestamp: format_timestamp(ts["executed_at"], draw.executed_at)
        }

      :failed ->
        %{
          label: "Winners Selected",
          detail: draw.failure_reason || "draw failed",
          state: :failed
        }

      _ ->
        %{label: "Winners Selected", detail: nil, state: :pending}
    end
  end

  defp entropy_detail(draw) do
    [
      if(draw.drand_randomness, do: "drand: #{truncate_hash(draw.drand_randomness)}"),
      if(draw.weather_value, do: "weather: #{draw.weather_value}"),
      if(draw.weather_observation_time,
        do: "observed at #{Calendar.strftime(draw.weather_observation_time, "%H:%M UTC")}"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp step_class(:done), do: "step step-done"
  defp step_class(:current), do: "step step-done step-current"
  defp step_class(:failed), do: "step step-failed"
  defp step_class(:pending), do: "step"

  defp format_timestamp(nil, nil), do: nil
  defp format_timestamp(nil, %DateTime{} = fallback), do: format_dt(fallback)

  defp format_timestamp(iso_string, _fallback) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> format_dt(dt)
      _ -> nil
    end
  end

  defp format_timestamp(nil), do: nil

  defp format_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> format_dt(dt)
      _ -> nil
    end
  end

  defp format_dt(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp truncate_hash(nil), do: "..."
  defp truncate_hash(hash) when byte_size(hash) > 12, do: String.slice(hash, 0, 12) <> "..."
  defp truncate_hash(hash), do: hash
end
