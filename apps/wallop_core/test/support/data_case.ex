defmodule WallopCore.DataCase do
  @moduledoc "ExUnit case template for tests requiring database access."
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias WallopCore.Repo
      import WallopCore.DataCase
    end
  end

  setup tags do
    WallopCore.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(WallopCore.Repo, shared: !tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end
end
