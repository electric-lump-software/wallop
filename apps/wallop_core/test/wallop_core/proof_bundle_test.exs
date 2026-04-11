defmodule WallopCore.ProofBundleTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.ProofBundle

  describe "build/1" do
    test "returns a canonical JSON binary for a completed draw with weather" do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      {:ok, json} = ProofBundle.build(executed)

      decoded = Jason.decode!(json)

      assert decoded["version"] == 1
      assert decoded["draw_id"] == executed.id
      assert is_list(decoded["entries"])
      assert is_list(decoded["results"])
      assert is_map(decoded["entropy"])
      assert is_map(decoded["lock_receipt"])
      assert is_map(decoded["execution_receipt"])
    end
  end
end
