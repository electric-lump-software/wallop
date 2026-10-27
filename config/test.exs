import Config

config :wallop_core, WallopCore.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "wallop_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :wallop_web, WallopWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-that-is-at-least-64-bytes-long-for-testing-purposes-only",
  server: false

config :bcrypt_elixir, log_rounds: 1

config :wallop_core, Oban, testing: :manual

config :wallop_core, WallopCore.Entropy.WeatherObservationWorker,
  land_obs_client: WallopCore.Test.WindowedLandObsClient

config :wallop_core, WallopCore.Entropy.DrandClient, bls: WallopCore.Test.DrandBls

config :wallop_core, :prepared_transactions_check, false

config :wallop_core, :vault_key_check, false

config :wallop_core, WallopCore.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
       iv_length: 12}
  ]

config :wallop_core, :met_office_obs_api_key, "test-placeholder"

config :wallop_web, :proof_storage,
  backend: WallopWeb.ProofStorage.Filesystem,
  filesystem: [
    root: Path.join(System.tmp_dir!(), "wallop_test_proof_pdfs_#{System.unique_integer([:positive])}")
  ]

config :opentelemetry,
  traces_exporter: :none

config :logger, level: :warning
