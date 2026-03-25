defmodule WallopCore.Entropy.EntropyWorker do
  @moduledoc """
  Oban worker that collects entropy sources for a draw.

  Scheduled to run at the draw's weather_time. Fetches drand randomness
  and weather data, computes the seed, and executes the draw.

  This is a stub — full implementation comes in Task 8.
  """
  use Oban.Worker, queue: :entropy, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"draw_id" => _draw_id}}) do
    # Stub: full implementation in Task 8
    :ok
  end
end
