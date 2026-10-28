import Config

if config_env() in [:dev, :test] do
  env = Dotenvy.source!([".env", System.get_env()])

  if obs_key = env["MET_OFFICE_OBS_API_KEY"] do
    config :wallop_core, :met_office_obs_api_key, obs_key
  end

  if config_env() == :dev do
    vault_key =
      env["VAULT_KEY"] ||
        raise """
        VAULT_KEY environment variable is not set.

        If you run another consumer of wallop_core against the same local
        Postgres database, both projects encrypt/decrypt each other's
        rows via WallopCore.Vault and MUST share the same VAULT_KEY.

        Copy the value from your other project's .env into this one — do
        not generate a fresh one for each. To mint a new one from scratch
        for both projects, use `openssl rand -base64 32` (not
        mix phx.gen.secret, which produces a double-encoded value).
        """

    vault_key_old = env["VAULT_KEY_OLD"]

    config :wallop_core, WallopCore.Vault,
      ciphers: WallopCore.Vault.Config.build_ciphers(vault_key, vault_key_old)
  end
end

config :wallop_core,
       :land_obs_daily_cap,
       WallopCore.Weather.LandObsBudget.parse_cap!(System.get_env("LAND_OBS_DAILY_CAP"))

if honeycomb_api_key = System.get_env("HONEYCOMB_API_KEY") do
  config :opentelemetry,
    resource: [service: [name: "wallop-core"]]

  config :opentelemetry_exporter,
    otlp_endpoint: "https://api.honeycomb.io",
    otlp_headers: [{"x-honeycomb-team", honeycomb_api_key}],
    otlp_protocol: :http_protobuf
end

if url = WallopWeb.ExampleProof.parse_env!(System.get_env("EXAMPLE_PROOF_URL")) do
  config :wallop_web, :example_proof_url, url
end

if config_env() == :prod do
  edge_shared_secret = System.get_env("EDGE_SHARED_SECRET")

  if edge_shared_secret != nil and byte_size(edge_shared_secret) < 32 do
    raise "EDGE_SHARED_SECRET is set but blank or shorter than 32 bytes; " <>
            "unset it to disable the edge guard"
  end

  config :wallop_web, WallopWeb.Plugs.EdgeGuard, secret: edge_shared_secret

  config :wallop_web, :warn_edge_secret_unset, is_nil(edge_shared_secret)

  case System.get_env("RATE_LIMIT_BACKEND", "ets") do
    "ets" ->
      :ok

    "redis" ->
      config :wallop_web, WallopWeb.RateLimiter,
        backend: :redis,
        redis_url: System.get_env("REDIS_URL")

    other ->
      raise "RATE_LIMIT_BACKEND must be ets or redis, got #{inspect(other)}"
  end

  if obs_key = System.get_env("MET_OFFICE_OBS_API_KEY") do
    config :wallop_core, :met_office_obs_api_key, obs_key
  end

  if redis_url = System.get_env("REDIS_URL") do
    config :wallop_core, :redis_url, redis_url
  end

  vault_key =
    System.get_env("VAULT_KEY") ||
      raise "VAULT_KEY environment variable is not set"

  vault_key_old = System.get_env("VAULT_KEY_OLD")

  config :wallop_core, WallopCore.Vault,
    ciphers: WallopCore.Vault.Config.build_ciphers(vault_key, vault_key_old)
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL environment variable is not set"

  config :wallop_core, WallopCore.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is not set"

  if byte_size(secret_key_base) < 64 do
    raise "SECRET_KEY_BASE is shorter than 64 bytes; generate one with `mix phx.gen.secret`"
  end

  host = System.get_env("PHX_HOST") || "localhost"

  case System.get_env("VERIFY_BLOCK_ANCHOR_MODE") do
    nil -> :ok
    "bundled" -> config :wallop_web, :verify_block_anchor_mode, :bundled
    "self" -> config :wallop_web, :verify_block_anchor_mode, :self
    other -> raise "VERIFY_BLOCK_ANCHOR_MODE must be \"bundled\" or \"self\", got: #{inspect(other)}"
  end

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :wallop_web, WallopWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port,
      thousand_island_options: [read_timeout: 10_000]
    ],
    secret_key_base: secret_key_base

  if gotenberg_url = System.get_env("GOTENBERG_URL") do
    config :wallop_web, :gotenberg_url, gotenberg_url
  end

  config :wallop_web,
         :proof_pdf_cache_enabled?,
         System.get_env("PROOF_PDF_CACHE_ENABLED", "true") == "true"

  if bucket = System.get_env("AWS_S3_BUCKET_NAME") do
    config :wallop_web, :proof_storage,
      backend: WallopWeb.ProofStorage.S3,
      s3: [
        bucket: bucket,
        prefix: System.get_env("AWS_S3_PROOF_PREFIX", "proof-pdfs")
      ]

    region =
      System.get_env("AWS_DEFAULT_REGION") || System.get_env("AWS_REGION") || "us-east-1"

    config :ex_aws,
      access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
      region: region

    endpoint_url =
      System.get_env("AWS_ENDPOINT_URL") || System.get_env("AWS_S3_ENDPOINT")

    if endpoint_url do
      uri = URI.parse(endpoint_url)

      config :ex_aws, :s3,
        scheme: (uri.scheme || "https") <> "://",
        host: uri.host,
        port: uri.port,
        region: region
    end
  end
end
