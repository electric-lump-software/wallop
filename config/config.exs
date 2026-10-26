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

# Oban config for the wallop service (processes draw jobs).
# Consuming apps MUST override this with a different prefix — see README.
config :wallop_core, Oban,
  repo: WallopCore.Repo,
  # Each entropy source has its own queue, so one source being slow (a
  # trickled Elexon response, a hostile drand relay) never holds another's
  # slots. :weather is the Land Obs fetch; :frequency the grid-frequency
  # window polls; :v6_execution the schema 6 executions
  # (ObservationDrawWorker, both tags).
  # The queue limits add up to 26, more than the Repo pool (POOL_SIZE,
  # default 20). That is safe because jobs check a connection out per query,
  # and no job wraps an HTTP call in a transaction or a checkout: the
  # fetching workers refuse to fetch inside a transaction, and a test
  # rejects checkouts in lib. Size the pool for queries running at the same
  # time, not for jobs.
  queues: [webhooks: 5, default: 5, weather: 5, frequency: 6, v6_execution: 5],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", WallopCore.Entropy.ExpiryWorker},
       {"30 3 * * *", WallopCore.Transparency.AnchorWorker},
       {"*/10 * * * *", WallopCore.Entropy.StuckDrawRedriver},
       # Runs on the weather queue: only the node that fetches records it.
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

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  wallop: [
    # `--minify` is part of the base profile so production deployments
    # always emit a minified bundle even if the deploy command forgets
    # to pass it explicitly. Dev's listener config appends `--watch
    # --sourcemap=inline` (see config/dev.exs) which still works with
    # minification — the inline sourcemap restores readable stack
    # traces.
    args:
      ~w(js/app.js --bundle --target=es2022 --minify --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --external:/assets/wasm/*),
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
      --minify
    ),
    cd: Path.expand("../apps/wallop_web/assets", __DIR__)
  ]

config :wallop_web, :proof_storage,
  backend: WallopWeb.ProofStorage.Filesystem,
  filesystem: [root: Path.expand("../priv/proof_pdfs", __DIR__)]

# Gotenberg sidecar (HTML → PDF via headless Chromium). Run locally with
# `docker run --rm -p 3000:3000 gotenberg/gotenberg:8`. Prod overrides
# via GOTENBERG_URL env var in runtime.exs.
config :wallop_web, :gotenberg_url, "http://localhost:3000"

# Rate limiter store: :ets (one node) or :redis (shared). Prod overrides via
# RATE_LIMIT_BACKEND in runtime.exs.
config :wallop_web, WallopWeb.RateLimiter, backend: :ets

# Which trust anchors the proof page's `wallop-verify` command relies on.
# `:bundled` — the verifier's compiled-in anchors (the released production
# deployment). `:self` — this instance's own infrastructure keys, supplied
# via `--infra-key-pin`, for deployments whose keys aren't in the released
# verifier (staging, dev, self-hosters). Defaults to `:bundled` so a
# misconfigured deployment fails verification loudly rather than quietly
# telling users to trust the server's own keys. See WallopWeb.VerifyCommand.
config :wallop_web, :verify_block_anchor_mode, :bundled

# ex_aws S3 client defaults. Prod overrides via env vars in runtime.exs.
config :ex_aws,
  json_codec: Jason,
  # Req rather than the ex_aws default of hackney. hackney 4.x ships its own
  # HTTP/2 app (`h2`) whose modules collide with grpcbox's chatterbox, which
  # opentelemetry_exporter pulls in — the two cannot coexist in one release.
  # Staying on hackney 1.x would instead mean carrying four open advisories.
  # Req is already a dependency and ex_aws supports it as a first-class client.
  http_client: ExAws.Request.Req

config :ash, :tracer, [OpentelemetryAsh]

# Count codepoints for `:string` min/max_length, matching Postgres, so
# `max_length` actually bounds stored size. (`:mixed` counts graphemes in
# Elixir, and one grapheme can carry unbounded combining characters.)
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
