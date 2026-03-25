defmodule WallopWeb.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: WallopWeb.PubSub},
      WallopWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: WallopWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
