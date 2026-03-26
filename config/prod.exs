import Config

# Production config — most values come from runtime.exs via env vars.
# This file only sets compile-time prod defaults.

config :wallop_web, WallopWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

config :logger, level: :info
