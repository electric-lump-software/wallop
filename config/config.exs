import Config

config :mime, :types, %{
  "application/vnd.api+json" => ["json"]
}

config :mime, :extensions, %{
  "json" => "application/json"
}

config :wallop_core,
  env: config_env(),
  ecto_repos: [WallopCore.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  ash_domains: [WallopCore.Domain],
  allow_sandbox_execution: config_env() != :prod

# Oban config for the wallop service (processes draw jobs).
# Consuming apps MUST override this with a different prefix — see README.
config :wallop_core, Oban,
  repo: WallopCore.Repo,
  queues: [entropy: 10, webhooks: 5, default: 5],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", WallopCore.Entropy.ExpiryWorker}
     ]}
  ]

config :wallop_web, WallopWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: WallopWeb.ErrorJSON]],
  pubsub_server: WallopCore.PubSub,
  live_view: [signing_salt: "Fp8kXm2Q"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  wallop: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/wallop_web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.18",
  wallop: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/wallop_web/assets", __DIR__)
  ]

config :ash, :tracer, [OpentelemetryAsh]

config :opentelemetry_ash,
  trace_types: [:custom, :action, :flow]

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
