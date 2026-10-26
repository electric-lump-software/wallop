defmodule WallopCore.Attacks.QueueIsolationTest do
  @moduledoc """
  Each entropy source's work has its own Oban queue, so one source being
  slow can't hold another's slots.

    * `FrequencyWindowWorker` once ran in `:weather`, the Land Obs fetch
      queue. About 14 windows are live at once, and a network attacker who
      trickles Elexon bytes makes every poll take its full 8 s fetch cap, so
      Land Obs fetches queued behind Elexon. It now runs in `:frequency`.
    * `ObservationDrawWorker` (schema 6 executions, both tags) runs in
      `:v6_execution`, apart from both fetch queues.

  The retired forecast worker's `:entropy` queue is gone.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.{
    FrequencyWindowWorker,
    ObservationDrawWorker,
    WeatherObservationWorker
  }

  defp queue(worker), do: worker.new(%{}).changes.queue

  defp configured_queues,
    do: Application.fetch_env!(:wallop_core, Oban) |> Keyword.fetch!(:queues)

  test "the frequency fetch and the v6 executions each have their own queue" do
    assert queue(FrequencyWindowWorker) == "frequency"
    assert queue(ObservationDrawWorker) == "v6_execution"

    assert queue(WeatherObservationWorker) == "weather"
    refute queue(FrequencyWindowWorker) == "weather"
    refute queue(ObservationDrawWorker) == "weather"
  end

  test "the Land Obs queue is unchanged, and the forecast queue is gone" do
    assert configured_queues()[:weather] == 5
    refute Keyword.has_key?(configured_queues(), :entropy)
  end

  test "the wallop service runs both new queues" do
    assert configured_queues()[:frequency] >= 2
    assert configured_queues()[:v6_execution] >= 2
  end
end
