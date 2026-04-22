defmodule WallopWeb.RevealDemoLive do
  @moduledoc """
  Dev-only page for testing the staged reveal animation.
  Not a real draw — just a visual harness.
  """
  use WallopWeb, :live_view

  import WallopWeb.Components.DrawTimeline

  @fake_draw_open %{
    id: "demo-00000000-0000-0000-0000-000000000000",
    status: :open,
    entries: [
      %{"ref" => "demo-alice", "weight" => 1},
      %{"ref" => "demo-bob", "weight" => 1},
      %{"ref" => "demo-charlie", "weight" => 2}
    ],
    entry_hash: nil,
    entry_canonical: nil,
    winner_count: 1,
    results: nil,
    seed: nil,
    seed_source: nil,
    seed_json: nil,
    drand_chain: nil,
    drand_round: nil,
    drand_randomness: nil,
    drand_signature: nil,
    drand_response: nil,
    weather_station: nil,
    weather_time: nil,
    weather_value: nil,
    weather_raw: nil,
    weather_observation_time: nil,
    executed_at: nil,
    failed_at: nil,
    failure_reason: nil,
    inserted_at: ~U[2026-01-01 11:50:00Z],
    stage_timestamps: %{
      "opened_at" => "2026-01-01T11:50:00Z"
    },
    callback_url: nil,
    metadata: nil
  }

  # Completed version for the final state after animation
  @fake_draw_completed %{
    id: "demo-00000000-0000-0000-0000-000000000000",
    status: :completed,
    entries: [
      %{"ref" => "demo-alice", "weight" => 1},
      %{"ref" => "demo-bob", "weight" => 1},
      %{"ref" => "demo-charlie", "weight" => 2}
    ],
    entry_hash: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
    entry_canonical: "{}",
    winner_count: 1,
    results: [%{"position" => 1, "entry_id" => "demo-bob"}],
    seed: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
    seed_source: :entropy,
    seed_json: "{}",
    drand_chain: "demo",
    drand_round: 12_345,
    drand_randomness: "fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321",
    drand_signature: "demo",
    drand_response: "{}",
    weather_station: "middle-wallop",
    weather_time: ~U[2026-01-01 12:00:00Z],
    weather_value: "101325",
    weather_raw: "{}",
    weather_observation_time: ~U[2026-01-01 11:00:00Z],
    executed_at: ~U[2026-01-01 12:10:00Z],
    failed_at: nil,
    failure_reason: nil,
    inserted_at: ~U[2026-01-01 11:50:00Z],
    stage_timestamps: %{
      "opened_at" => "2026-01-01T11:50:00Z",
      "locked_at" => "2026-01-01T11:55:00Z",
      "entropy_declared_at" => "2026-01-01T11:55:00Z"
    },
    callback_url: nil,
    metadata: nil
  }

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       draw: @fake_draw_open,
       revealing: false,
       mode: :step,
       page_title: "Reveal Demo"
     )}
  end

  def handle_event("start_reveal", _params, socket) do
    {:noreply, assign(socket, revealing: true, mode: :auto)}
  end

  def handle_event("start_stepping", _params, socket) do
    {:noreply, assign(socket, revealing: true, mode: :step)}
  end

  def handle_event("next_step", _params, socket) do
    {:noreply, push_event(socket, "reveal_next", %{})}
  end

  def handle_event("reveal_complete", _params, socket) do
    {:noreply, assign(socket, draw: @fake_draw_completed, revealing: false)}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, assign(socket, draw: @fake_draw_open, revealing: false)}
  end
end
