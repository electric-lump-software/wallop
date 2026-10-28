defmodule WallopCore.Application do
  @moduledoc false
  use Application

  require Logger

  alias WallopCore.Drand.Bls
  alias WallopCore.Telemetry.{EctoHandler, ObanShutdownHandler}
  alias WallopCore.Weather.{LandObsBudget, ObservationReadiness}

  @impl true
  def start(_type, _args) do
    warn_if_default_oban_prefix()
    warn_if_low_land_obs_cap()
    assert_vault_key_present!()
    Bls.self_test!()

    OpentelemetryOban.setup(plugin: :disabled)
    EctoHandler.setup([:wallop_core, :repo])
    ObanShutdownHandler.attach()

    opts = [strategy: :one_for_one, name: WallopCore.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc false
  def children do
    [WallopCore.Repo, WallopCore.Vault] ++
      vault_key_check() ++
      [
        pubsub_child_spec(),
        {Oban, Application.fetch_env!(:wallop_core, Oban)},
        Supervisor.child_spec({Task, &ObservationReadiness.publish_at_boot/0},
          id: :observation_readiness_boot
        )
      ] ++ prepared_transactions_check()
  end

  defp vault_key_check do
    if Application.get_env(:wallop_core, :vault_key_check, true),
      do: [WallopCore.VaultKeyCheck],
      else: []
  end

  defp prepared_transactions_check do
    if Application.get_env(:wallop_core, :prepared_transactions_check, true),
      do: [WallopCore.PreparedTransactionsCheck],
      else: []
  end

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
      This means your app will compete with the wallop service for draw
      and webhook jobs. Set a different prefix in your config:

          config :wallop_core, Oban,
            repo: WallopCore.Repo,
            prefix: "oban_app",
            queues: [webhooks: 5, default: 5, weather: 5, frequency: 6, v6_execution: 5],
            plugins: []
      """)
    end
  end

  defp warn_if_low_land_obs_cap do
    if warning = LandObsBudget.boot_warning(LandObsBudget.cap()) do
      Logger.warning(warning)
    end
  end

  defp pubsub_child_spec do
    case Application.get_env(:wallop_core, :redis_url) do
      url when is_binary(url) and url != "" ->
        if Node.alive?() do
          {Phoenix.PubSub, name: WallopCore.PubSub, adapter: Phoenix.PubSub.Redis, url: url}
        else
          {Phoenix.PubSub, name: WallopCore.PubSub}
        end

      _ ->
        case Application.get_env(:wallop_core, :pubsub) do
          opts when is_list(opts) ->
            {Phoenix.PubSub, Keyword.put_new(opts, :name, WallopCore.PubSub)}

          _ ->
            {Phoenix.PubSub, name: WallopCore.PubSub}
        end
    end
  end
end
