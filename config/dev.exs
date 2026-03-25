import Config

config :wallop_core, WallopCore.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "wallop_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :wallop_web, WallopWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-development-use-only",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:wallop, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:wallop, ~w(--watch)]}
  ]

config :wallop_web, WallopWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/.*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/wallop_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true

config :wallop_core, WallopCore.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")}
  ]

config :wallop_core, :met_office_api_key, System.get_env("MET_OFFICE_API_KEY", "dev-placeholder")
