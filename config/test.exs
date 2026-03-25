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

config :logger, level: :warning
