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

    test "is byte-deterministic across repeated calls (regression: PAM-117)" do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)

      # Create a draw with several entries — enough that any non-deterministic
      # ordering of Entries.load_for_draw/1 would surface as a byte difference.
      entries = for n <- 1..20, do: %{"id" => "entry-#{n}", "weight" => 1}
      draw = create_draw(api_key, %{entries: entries})
      executed = execute_draw(draw, test_seed(), api_key)

      {:ok, first} = ProofBundle.build(executed)
      {:ok, second} = ProofBundle.build(executed)
      {:ok, third} = ProofBundle.build(executed)

      assert first == second
      assert second == third
    end

    test "returns error for non-completed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert {:error, :draw_not_completed} = ProofBundle.build(draw)
    end

    test "omits weather_value entirely for drand-only draws" do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)

      executed =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)
        |> Ash.Changeset.for_update(:execute_drand_only, %{
          drand_randomness: test_drand_randomness(),
          drand_signature: "test-signature",
          drand_response: "{}",
          weather_fallback_reason: "manual override for test"
        })
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      {:ok, json} = ProofBundle.build(executed)
      decoded = Jason.decode!(json)

      refute Map.has_key?(decoded["entropy"], "weather_value")
      assert decoded["entropy"]["drand_randomness"] == test_drand_randomness()
    end
  end
end
