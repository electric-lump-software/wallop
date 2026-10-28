defmodule WallopCore.DeployDrainConfigTest do
  @moduledoc """
  Locks the deploy drain budget. Oban's shutdown grace period must outlast
  the longest job timeout, and Railway's SIGTERM-to-SIGKILL drain must
  outlast the grace period with room for the rest of the node to stop.
  If either is lowered, a deploy can kill jobs mid-run.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.{
    FrequencyWindowWorker,
    ObservationDrawWorker,
    WeatherObservationWorker
  }

  @workers [WeatherObservationWorker, FrequencyWindowWorker, ObservationDrawWorker]
  @railway_toml Path.expand("../../../../railway.toml", __DIR__)

  defp grace_ms,
    do: Keyword.fetch!(Application.fetch_env!(:wallop_core, Oban), :shutdown_grace_period)

  defp max_timeout_ms, do: @workers |> Enum.map(& &1.timeout(%Oban.Job{})) |> Enum.max()

  defp draining_seconds do
    @railway_toml
    |> File.read!()
    |> String.split(~r/^\s*\[/m)
    |> Enum.find(&String.starts_with?(&1, "deploy]"))
    |> then(&Regex.run(~r/^\s*drainingSeconds\s*=\s*(\d+)\s*$/m, &1, capture: :all_but_first))
    |> case do
      [value] -> String.to_integer(value)
      nil -> flunk("railway.toml [deploy] has no drainingSeconds")
    end
  end

  test "every worker timeout is a finite number of milliseconds" do
    for worker <- @workers, do: assert(is_integer(worker.timeout(%Oban.Job{})))
  end

  test "Oban's shutdown grace outlasts the longest job timeout by at least 5 s" do
    assert grace_ms() > max_timeout_ms() + 5_000
  end

  test "Railway's drain outlasts Oban's shutdown grace by at least 30 s" do
    assert draining_seconds() >= div(grace_ms(), 1_000) + 30
  end
end
