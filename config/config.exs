import Config

config :wallop_core,
  ecto_repos: [WallopCore.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  ash_domains: [WallopCore.Domain]

config :wallop_web, WallopWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: WallopWeb.ErrorJSON]]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
