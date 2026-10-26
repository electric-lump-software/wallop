defmodule WallopCore.Release do
  @moduledoc """
  Release tasks for running migrations in production.
  """

  @app :wallop_core

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  The forecast retirement gate, before a deploy (read-only): stranded
  forecast draws and live jobs of the old forecast worker. Both should be
  0. Runs on its own, with only the repo started:
  `bin/wallop eval "WallopCore.Release.forecast_drain_report()"`.
  See `WallopCore.ForecastDrain`.
  """
  def forecast_drain_report do
    load_app()

    {:ok, report, _} =
      Ecto.Migrator.with_repo(WallopCore.Repo, fn _repo -> WallopCore.ForecastDrain.report() end)

    report
  end

  @doc """
  The forecast retirement gate, after a deploy, once the last old container
  has stopped: fails each stranded forecast draw with reason
  `"forecast_retired"` and cancels the old forecast worker's live jobs.
  Run it inside the running service, where Oban is up:
  `bin/wallop rpc "WallopCore.Release.drain_retired_forecast() |> IO.inspect()"`.
  See `WallopCore.ForecastDrain`.
  """
  def drain_retired_forecast, do: WallopCore.ForecastDrain.drain()

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
