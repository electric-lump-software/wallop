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

    test "is byte-deterministic across repeated calls" do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)

      entries =
        for n <- 1..20 do
          padded = String.pad_leading(Integer.to_string(n), 2, "0")
          %{"ref" => "entry-#{padded}", "weight" => 1}
        end

      draw = create_draw(api_key, %{entries: entries})
      executed = execute_draw(draw, test_seed(), api_key)

      {:ok, first} = ProofBundle.build(executed)
      {:ok, second} = ProofBundle.build(executed)
      {:ok, third} = ProofBundle.build(executed)

      assert first == second
      assert second == third

      # The bundle sorts entries by uuid — byte-determinism depends on that
      # ordering being stable regardless of DB return order.
      decoded = Jason.decode!(first)
      uuids = Enum.map(decoded["entries"], & &1["uuid"])
      assert uuids == Enum.sort(uuids)
      assert length(uuids) == 20
    end

    test "returns error for non-completed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert {:error, :draw_not_completed} = ProofBundle.build(draw)
    end

    test "bundle entries reproduce the committed entry_hash (public-verifier invariant)" do
      # Durable invariant: anything a commitment hashes must be derivable
      # from public bundle bytes alone. A third-party verifier reading the
      # public ProofBundle and recomputing the canonical form MUST reproduce
      # the entry_hash inside the signed lock receipt — otherwise the bundle
      # is unverifiable by anyone outside wallop.
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)

      draw =
        create_draw(api_key, %{
          entries: [
            %{"weight" => 1},
            %{"weight" => 1},
            %{"weight" => 1}
          ]
        })

      executed = execute_draw(draw, test_seed(), api_key)

      {:ok, bundle_json} = ProofBundle.build(executed)
      bundle = Jason.decode!(bundle_json)

      # Reconstruct the entry_hash input from the public bundle bytes only.
      bundle_entries =
        Enum.map(bundle["entries"], fn e ->
          %{uuid: e["uuid"], weight: e["weight"]}
        end)

      {recomputed_hash, _jcs} =
        WallopCore.Protocol.entry_hash({bundle["draw_id"], bundle_entries})

      lock_payload = Jason.decode!(bundle["lock_receipt"]["payload_jcs"])
      committed_hash = lock_payload["entry_hash"]

      assert recomputed_hash == committed_hash,
             "public bundle cannot reproduce committed entry_hash — " <>
               "the canonical form depends on data not present in the public bundle"
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
