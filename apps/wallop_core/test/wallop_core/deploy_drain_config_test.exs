defmodule WallopCore.DeployDrainConfigTest do
  @moduledoc """
  Locks the deploy drain budget. Every Oban worker in wallop_core must have
  a finite timeout, Oban's shutdown grace period must outlast the longest of
  them, Lifeline must not rescue a job before the grace period is over (or a
  job still draining on the old node could run again on the new one), and
  Railway's SIGTERM-to-SIGKILL drain must outlast the grace period with room
  for the rest of the node to stop.

  Workers are found from the application's module list, so a new worker
  without a timeout fails here. A worker whose `timeout/1` matches on its
  args needs a sample job in `@sample_jobs`.
  """
  use ExUnit.Case, async: true

  @sample_jobs %{}
  @railway_toml Path.expand("../../../../railway.toml", __DIR__)

  defp workers do
    {:ok, modules} = :application.get_key(:wallop_core, :modules)

    Enum.filter(modules, fn module ->
      Code.ensure_loaded?(module) and Oban.Worker in behaviours(module)
    end)
  end

  defp behaviours(module) do
    module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  end

  defp timeout_of(worker) do
    job = Map.get(@sample_jobs, worker, %Oban.Job{args: %{}, worker: inspect(worker)})
    worker.timeout(job)
  rescue
    FunctionClauseError ->
      flunk("#{inspect(worker)}.timeout/1 needs a sample job in @sample_jobs")
  end

  defp oban_config, do: Application.fetch_env!(:wallop_core, Oban)

  defp grace_ms, do: Keyword.fetch!(oban_config(), :shutdown_grace_period)

  defp rescue_after_ms do
    oban_config()
    |> Keyword.fetch!(:plugins)
    |> Enum.find_value(fn
      {Oban.Plugins.Lifeline, opts} -> Keyword.fetch!(opts, :rescue_after)
      _ -> nil
    end)
    |> case do
      nil -> flunk("no Oban.Plugins.Lifeline in the Oban plugins")
      ms -> ms
    end
  end

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

  test "the worker list is found" do
    assert WallopCore.Entropy.WebhookWorker in workers()
    assert WallopCore.Entropy.ObservationDrawWorker in workers()
  end

  test "every worker has a finite timeout in milliseconds" do
    for worker <- workers() do
      timeout = timeout_of(worker)

      assert is_integer(timeout) and timeout > 0,
             "#{inspect(worker)}.timeout/1 returned #{inspect(timeout)}"
    end
  end

  test "Oban's shutdown grace outlasts the longest job timeout by more than 5 s" do
    {worker, longest} = workers() |> Enum.map(&{&1, timeout_of(&1)}) |> Enum.max_by(&elem(&1, 1))

    assert longest + 5_000 < grace_ms(),
           "#{inspect(worker)} times out at #{longest} ms; grace is #{grace_ms()} ms"
  end

  test "Lifeline does not rescue a job before the shutdown grace is over" do
    assert grace_ms() < rescue_after_ms()
  end

  test "Railway's drain outlasts Oban's shutdown grace by at least 30 s" do
    assert draining_seconds() >= div(grace_ms(), 1_000) + 30
  end
end
