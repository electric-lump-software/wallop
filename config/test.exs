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

config :wallop_core, WallopCore.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")}
  ]

config :wallop_core, :met_office_api_key, "test-placeholder"

# In-memory proof storage for tests (use a unique tmp dir per run)
config :wallop_web, :proof_storage,
  backend: WallopWeb.ProofStorage.Filesystem,
  filesystem: [
    root: Path.join(System.tmp_dir!(), "wallop_test_proof_pdfs_#{System.unique_integer([:positive])}")
  ]

config :opentelemetry,
  traces_exporter: :none

config :logger, level: :warning
