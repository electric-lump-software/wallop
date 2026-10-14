defmodule WallopWeb.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    WallopCore.VaultHealthCheck.check!(WallopCore.Vault)

    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryBandit.setup()

    children = [
      # Must start before the endpoint so the rate-limit tables exist, and are
      # owned by a supervised process, before the first request is served.
      WallopWeb.RateLimiter,
      WallopWeb.RateLimit.Sweeper,
      WallopWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: WallopWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
