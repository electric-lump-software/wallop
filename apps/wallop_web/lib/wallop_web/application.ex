defmodule WallopWeb.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    WallopCore.VaultHealthCheck.check!(WallopCore.Vault)

    warn_if_edge_secret_unset()

    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryBandit.setup()

    children = [
      WallopWeb.RateLimiter,
      {Task.Supervisor, name: WallopWeb.TaskSupervisor},
      WallopWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: WallopWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp warn_if_edge_secret_unset do
    if Application.get_env(:wallop_web, :warn_edge_secret_unset, false) do
      Logger.error(
        "EDGE_SHARED_SECRET is not set: per-IP rate limits trust the client-supplied " <>
          "cf-connecting-ip header, so the origin must not be reachable except through the edge."
      )
    end
  end
end
