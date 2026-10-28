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
  ash_domains: [WallopCore.Domain]

config :wallop_core, Oban,
  repo: WallopCore.Repo,
  queues: [webhooks: 5, default: 5, weather: 5, frequency: 6, v6_execution: 5],
  shutdown_grace_period: :timer.seconds(100),
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", WallopCore.Entropy.ExpiryWorker},
       {"30 3 * * *", WallopCore.Transparency.AnchorWorker},
       {"*/10 * * * *", WallopCore.Entropy.StuckDrawRedriver},
       {"*/10 * * * *", WallopCore.Weather.ObservationReadinessWorker}
     ]},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(2)}
  ]

config :wallop_web, WallopWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: WallopWeb.ErrorJSON]],
  pubsub_server: WallopCore.PubSub,
  live_view: [signing_salt: "Fp8kXm2Q"]

config :esbuild,
  version: "0.25.4",
  wallop: [
    args:
      ~w(js/app.js --bundle --target=es2022 --minify --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --external:/assets/wasm/*),
    cd: Path.expand("../apps/wallop_web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "4.1.18",
  wallop: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
      --minify
    ),
    cd: Path.expand("../apps/wallop_web/assets", __DIR__)
  ]

config :wallop_web, :proof_storage,
  backend: WallopWeb.ProofStorage.Filesystem,
  filesystem: [root: Path.expand("../priv/proof_pdfs", __DIR__)]

config :wallop_web, :gotenberg_url, "http://localhost:3000"

config :wallop_web, WallopWeb.RateLimiter, backend: :ets

config :wallop_web, :verify_block_anchor_mode, :bundled

config :ex_aws,
  json_codec: Jason,
  http_client: ExAws.Request.Req

config :ash, :tracer, [OpentelemetryAsh]

config :ash, default_string_length_count: :codepoints

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
