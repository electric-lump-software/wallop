import Config

if config_env() in [:dev, :test] do
  env = Dotenvy.source!([".env", System.get_env()])

  if met_key = env["MET_OFFICE_API_KEY"] do
    config :wallop_core, :met_office_api_key, met_key
  end
end

if honeycomb_api_key = System.get_env("HONEYCOMB_API_KEY") do
  config :opentelemetry,
    resource: [service: [name: "wallop-core"]]

  config :opentelemetry_exporter,
    otlp_endpoint: "https://api.honeycomb.io",
    otlp_headers: [{"x-honeycomb-team", honeycomb_api_key}],
    otlp_protocol: :http_protobuf
end

if config_env() == :prod do
  met_office_api_key =
    System.get_env("MET_OFFICE_API_KEY") ||
      raise "MET_OFFICE_API_KEY environment variable is not set"

  config :wallop_core, :met_office_api_key, met_office_api_key

  if redis_url = System.get_env("REDIS_URL") do
    config :wallop_core, :redis_url, redis_url
  end

  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise "CLOAK_KEY environment variable is not set"

  config :wallop_core, WallopCore.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key)}
    ]
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL environment variable is not set"

  config :wallop_core, WallopCore.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is not set"

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :wallop_web, WallopWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  if gotenberg_url = System.get_env("GOTENBERG_URL") do
    config :wallop_web, :gotenberg_url, gotenberg_url
  end

  # Proof PDF storage. If AWS_S3_BUCKET_NAME is set we use the S3
  # backend, otherwise fall back to the local filesystem (useful for
  # self-hosters). Name matches Railway's convention.
  if bucket = System.get_env("AWS_S3_BUCKET_NAME") do
    config :wallop_web, :proof_storage,
      backend: WallopWeb.ProofStorage.S3,
      s3: [
        bucket: bucket,
        prefix: System.get_env("AWS_S3_PROOF_PREFIX", "proof-pdfs")
      ]

    config :ex_aws,
      access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
      region: System.get_env("AWS_REGION", "us-east-1")

    if endpoint = System.get_env("AWS_S3_ENDPOINT") do
      config :ex_aws, :s3,
        scheme: "https://",
        host: endpoint,
        region: System.get_env("AWS_REGION", "us-east-1")
    end
  end
end
