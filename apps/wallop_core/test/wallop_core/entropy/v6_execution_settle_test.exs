defmodule WallopCore.Entropy.V6ExecutionSettleTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Entropy.V6Execution

  describe "losing a race to a finished draw" do
    test "is success when the draw is already terminal" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      draw
      |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "other worker"})
      |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      assert :ok = V6Execution.settle_after_error(draw.id, :stale)
    end

    test "is success when the draw has completed" do
      api_key = create_api_key()
      done = execute_draw(create_draw(api_key))
      assert done.status == :completed

      assert :ok = V6Execution.settle_after_error(done.id, :stale)
    end

    test "is still an error when the draw is not terminal" do
      api_key = create_api_key()
      draw = create_draw(api_key)
      assert {:error, :stale} = V6Execution.settle_after_error(draw.id, :stale)
    end

    test "is still an error when the draw doesn't exist" do
      assert {:error, :stale} = V6Execution.settle_after_error(Ecto.UUID.generate(), :stale)
    end
  end
end
