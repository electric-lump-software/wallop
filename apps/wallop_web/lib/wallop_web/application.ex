defmodule WallopWeb.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    WallopCore.VaultHealthCheck.check!(WallopCore.Vault)

    warn_about_edge_secrets()

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

  defp warn_about_edge_secrets do
    if Application.get_env(:wallop_web, :warn_edge_previous_secret_set, false) do
      Logger.warning(
        "EDGE_SHARED_SECRET_PREVIOUS is set, so the edge guard also accepts it. " <>
          "Remove it once the edge sends the current value."
      )
    end

    if Application.get_env(:wallop_web, :warn_edge_secret_unset, false) do
      Logger.error(
        "EDGE_SHARED_SECRET is not set: per-IP rate limits trust the client-supplied " <>
          "cf-connecting-ip header, so the origin must not be reachable except through the edge."
      )
    end
  end
end
