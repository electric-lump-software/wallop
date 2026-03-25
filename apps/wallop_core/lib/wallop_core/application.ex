defmodule WallopCore.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WallopCore.Repo,
      WallopCore.Vault,
      {Oban, Application.fetch_env!(:wallop_core, Oban)}
    ]

    opts = [strategy: :one_for_one, name: WallopCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
