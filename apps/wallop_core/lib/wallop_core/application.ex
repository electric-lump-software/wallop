defmodule WallopCore.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WallopCore.Repo,
      WallopCore.Vault,
      pubsub_child_spec(),
      {Oban, Application.fetch_env!(:wallop_core, Oban)}
    ]

    opts = [strategy: :one_for_one, name: WallopCore.Supervisor]
    Supervisor.start_link(children, opts)
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
