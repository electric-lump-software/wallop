defmodule WallopWeb.ConnCase do
  @moduledoc "ExUnit case template for tests requiring a Phoenix conn."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import WallopWeb.ConnCase
      import WallopCore.TestHelpers

      @endpoint WallopWeb.Endpoint
    end
  end

  setup tags do
    WallopCore.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
