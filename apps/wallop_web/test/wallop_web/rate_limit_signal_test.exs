defmodule WallopWeb.RateLimitSignalTest do
  use ExUnit.Case, async: true

  alias WallopWeb.RateLimitSignal

  test "quota_limited is no longer a pressure kind" do
    assert_raise FunctionClauseError, fn ->
      RateLimitSignal.emit(Ecto.UUID.generate(), :quota_limited, 1)
    end
  end
end
