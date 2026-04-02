defmodule WallopCore.Application do
  @moduledoc false
  use Application

  require Logger

  alias WallopCore.Telemetry.EctoHandler

  @impl true
  def start(_type, _args) do
    warn_if_default_oban_prefix()

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
        {Phoenix.PubSub, name: WallopCore.PubSub, adapter: Phoenix.PubSub.Redis, url: url}

      _ ->
        # Allow consumers (e.g. wallop-app) to provide full PubSub config
        case Application.get_env(:wallop_core, :pubsub) do
          opts when is_list(opts) ->
            {Phoenix.PubSub, Keyword.put_new(opts, :name, WallopCore.PubSub)}

          _ ->
            {Phoenix.PubSub, name: WallopCore.PubSub}
        end
    end
  end
end
