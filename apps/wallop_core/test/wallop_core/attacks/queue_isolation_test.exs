defmodule WallopCore.Attacks.QueueIsolationTest do
  @moduledoc """
  Each entropy source's work has its own Oban queue, so one source being
  slow can't hold another's slots.

    * `FrequencyWindowWorker` once ran in `:weather`, the Land Obs fetch
      queue. About 14 windows are live at once, and a network attacker who
      trickles Elexon bytes makes every poll take its full 8 s fetch cap, so
      Land Obs fetches queued behind Elexon. It now runs in `:frequency`.
    * `ObservationDrawWorker` (schema 6 executions, both tags) once ran in
      `:entropy`, the forecast `EntropyWorker`'s queue. A burst of
      grid-frequency draws on one `draw_at`, with a slow drand relay, pushed
      live forecast executions back. It now runs in `:v6_execution`.

  Neither changed an outcome; the second changed the live forecast path's
  behaviour, which must not happen.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.{
    EntropyWorker,
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

    shared = [queue(EntropyWorker), queue(WeatherObservationWorker)]
    assert shared == ["entropy", "weather"]
    refute queue(FrequencyWindowWorker) in shared
    refute queue(ObservationDrawWorker) in shared
  end

  test "the forecast and Land Obs queues are unchanged" do
    assert queue(EntropyWorker) == "entropy"
    assert queue(WeatherObservationWorker) == "weather"
    assert configured_queues()[:entropy] == 10
    assert configured_queues()[:weather] == 5
  end

  test "the wallop service runs both new queues" do
    assert configured_queues()[:frequency] >= 2
    assert configured_queues()[:v6_execution] >= 2
  end
end
