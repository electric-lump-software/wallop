defmodule WallopCore.Application do
  @moduledoc false
  use Application

  require Logger

  alias WallopCore.Telemetry.EctoHandler

  @impl true
  def start(_type, _args) do
    warn_if_default_oban_prefix()
    assert_vault_key_present!()

    OpentelemetryOban.setup(plugin: :disabled)
    EctoHandler.setup([:wallop_core, :repo])

    children = [
      WallopCore.Repo,
      WallopCore.Vault,
      pubsub_child_spec(),
      {Oban, Application.fetch_env!(:wallop_core, Oban)}
    ]

    opts = [strategy: :one_for_one, name: WallopCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # `runtime.exs` raises if `VAULT_KEY` is unset, but only on a release-
  # bootstrap path that loads runtime.exs. A code path that constructs
  # the Vault without going through `runtime.exs` (test, release task,
  # mix command without `Mix.Tasks.Loadconfig`) would silently get
  # whatever Cloak default is configured and produce ciphertext that
  # decrypts to garbage on production reload.
  #
  # Crash the boot at supervisor start-up if the default cipher's key
  # is not a 32-byte binary. Costs effectively nothing; eliminates the
  # silent-fallback class.
  defp assert_vault_key_present! do
    config = Application.get_env(:wallop_core, WallopCore.Vault)

    unless is_list(config) do
      raise vault_misconfig_error(
              "expected a keyword list under config :wallop_core, WallopCore.Vault",
              config
            )
    end

    case Keyword.get(Keyword.get(config, :ciphers, []), :default) do
      {_module, opts} when is_list(opts) ->
        assert_vault_key_bytes!(Keyword.get(opts, :key))

      other ->
        raise vault_misconfig_error(
                "expected a default cipher entry under ciphers[:default]",
                other
              )
    end
  end

  defp assert_vault_key_bytes!(key) when is_binary(key) and byte_size(key) == 32, do: :ok

  defp assert_vault_key_bytes!(key) do
    raise """
    WallopCore.Vault is misconfigured. The default cipher requires a 32-byte key
    but got #{inspect(key, limit: 8)} (#{inspect(byte_size_or_nil(key))} bytes).
    Did the runtime config provider apply VAULT_KEY?
    """
  end

  defp vault_misconfig_error(detail, value) do
    "WallopCore.Vault is misconfigured. #{detail}, got #{inspect(value)}."
  end

  defp byte_size_or_nil(nil), do: nil
  defp byte_size_or_nil(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_nil(_), do: nil

  defp warn_if_default_oban_prefix do
    oban_config = Application.get_env(:wallop_core, Oban, [])
    prefix = Keyword.get(oban_config, :prefix)
    queues = Keyword.get(oban_config, :queues, [])

    is_umbrella = Application.spec(:wallop_web) != nil

    if !is_umbrella and prefix in [nil, "public"] and queues != false do
      Logger.warning("""
      [WallopCore] Oban is using the default prefix in a consuming app.
      This means your app will compete with the wallop service for entropy
      and webhook jobs. Set a different prefix in your config:

          config :wallop_core, Oban,
            repo: WallopCore.Repo,
            prefix: "oban_app",
            queues: [entropy: 10, webhooks: 5, default: 5],
            plugins: []
      """)
    end
  end

  defp pubsub_child_spec do
    case Application.get_env(:wallop_core, :redis_url) do
      url when is_binary(url) and url != "" ->
        if Node.alive?() do
          {Phoenix.PubSub, name: WallopCore.PubSub, adapter: Phoenix.PubSub.Redis, url: url}
        else
          # Unnamed node (e.g. mix task via one-off runner) — Redis PubSub
          # requires a named node. Fall back to local PubSub.
          {Phoenix.PubSub, name: WallopCore.PubSub}
        end

      _ ->
        # Allow downstream consumers to provide full PubSub config
        case Application.get_env(:wallop_core, :pubsub) do
          opts when is_list(opts) ->
            {Phoenix.PubSub, Keyword.put_new(opts, :name, WallopCore.PubSub)}

          _ ->
            {Phoenix.PubSub, name: WallopCore.PubSub}
        end
    end
  end
end
