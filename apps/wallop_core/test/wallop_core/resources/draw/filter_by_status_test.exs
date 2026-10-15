defmodule WallopCore.Resources.Draw.FilterByStatusTest do
  use WallopCore.DataCase, async: true

  import WallopCore.TestHelpers

  alias WallopCore.Resources.Draw

  test "a non-string status is a read error, not a crash" do
    query = Ash.Query.for_read(Draw, :list, %{status: ["open"]}, actor: create_api_key())

    assert {:error, _} = Ash.read(query)
  end
end
