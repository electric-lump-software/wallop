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
      # Must start before the endpoint so the rate-limit table exists, and is
      # owned by a supervised process, before the first request is served.
      WallopWeb.RateLimiter,
      WallopWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: WallopWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Set by config/runtime.exs in prod only. The edge secret stays optional
  # (self-hosters, dev and test run without it), but without it per-IP limits
  # key on a header any direct caller can forge.
  defp warn_if_edge_secret_unset do
    if Application.get_env(:wallop_web, :warn_edge_secret_unset, false) do
      Logger.error(
        "EDGE_SHARED_SECRET is not set: per-IP rate limits trust the client-supplied " <>
          "cf-connecting-ip header, so the origin must not be reachable except through the edge."
      )
    end
  end
end
