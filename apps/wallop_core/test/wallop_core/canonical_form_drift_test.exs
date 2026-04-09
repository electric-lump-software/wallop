defmodule WallopCore.CanonicalFormDriftTest do
  @moduledoc """
  Canonical form drift regression tests.

  Verifies that the entry_hash and receipt payloads computed at lock/execute
  time can be reconstructed from a fresh DB read. If any test here fails,
  the canonical form has drifted between the write path and the read path,
  which means historical proofs are unverifiable.

  This catches the class of bug Colin identified: "JCS is correct in
  isolation but the inputs to JCS are assembled by Elixir code that sorts,
  normalises, trims. Any divergence between the canonical form at commit
  time and the canonical form at verify time is a silent fairness break."
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers
  require Ash.Query

  alias WallopCore.Protocol
  alias WallopCore.Resources.{ExecutionReceipt, OperatorReceipt}

  describe "entry_hash round-trip (DB read matches locked value)" do
    test "entries loaded from DB produce the same hash as lock time" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)

      # Reload entries from the entries table (the "verifier path")
      entries_from_db = WallopCore.Entries.load_for_draw(draw.id)

      # Recompute entry_hash from the DB entries
      {recomputed_hash, recomputed_canonical} = Protocol.entry_hash(entries_from_db)

      # Must match the hash stored on the draw at lock time
      assert recomputed_hash == draw.entry_hash
      assert recomputed_canonical == draw.entry_canonical
    end

    test "entry ordering is deterministic regardless of insertion order" do
      api_key = create_api_key()

      # Insert entries in reverse alphabetical order
      draw =
        create_draw(api_key, %{
          entries: [
            %{"id" => "zebra", "weight" => 1},
            %{"id" => "apple", "weight" => 1},
            %{"id" => "mango", "weight" => 1}
          ]
        })

      entries = WallopCore.Entries.load_for_draw(draw.id)
      {hash, _} = Protocol.entry_hash(entries)

      # Same entries in a different insertion order must produce same hash
      api_key2 = create_api_key("key-2")

      draw2 =
        create_draw(api_key2, %{
          entries: [
            %{"id" => "mango", "weight" => 1},
            %{"id" => "zebra", "weight" => 1},
            %{"id" => "apple", "weight" => 1}
          ]
        })

      entries2 = WallopCore.Entries.load_for_draw(draw2.id)
      {hash2, _} = Protocol.entry_hash(entries2)

      assert hash == hash2
    end

    test "weighted entries round-trip correctly" do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          entries: [
            %{"id" => "heavy", "weight" => 100},
            %{"id" => "light", "weight" => 1},
            %{"id" => "medium", "weight" => 10}
          ],
          winner_count: 1
        })

      entries = WallopCore.Entries.load_for_draw(draw.id)
      {hash, _} = Protocol.entry_hash(entries)
      assert hash == draw.entry_hash
    end
  end

  describe "lock receipt payload round-trip" do
    test "receipt payload can be reconstructed from DB and signature verifies" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)

      [receipt] =
        OperatorReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      # Decode the stored payload and verify structure
      decoded = Jason.decode!(receipt.payload_jcs)

      # All expected fields present with correct types
      assert decoded["schema_version"] == "2"
      assert decoded["draw_id"] == draw.id
      assert decoded["operator_id"] == draw.operator_id
      assert is_binary(decoded["operator_slug"])
      assert is_integer(decoded["sequence"])
      assert is_binary(decoded["commitment_hash"])
      assert is_binary(decoded["entry_hash"])
      assert is_binary(decoded["locked_at"])
      assert is_binary(decoded["signing_key_id"])
      assert is_integer(decoded["winner_count"])
      assert is_binary(decoded["wallop_core_version"])
      assert is_binary(decoded["fair_pick_version"])

      # entry_hash in the receipt matches what we'd compute from DB
      entries = WallopCore.Entries.load_for_draw(draw.id)
      {recomputed_hash, _} = Protocol.entry_hash(entries)
      assert decoded["entry_hash"] == recomputed_hash

      # Verify the signature still works against the stored payload bytes
      [signing_key] =
        WallopCore.Resources.OperatorSigningKey
        |> Ash.Query.filter(operator_id == ^operator.id)
        |> Ash.read!(authorize?: false)

      assert Protocol.verify_receipt(
               receipt.payload_jcs,
               receipt.signature,
               signing_key.public_key
             )
    end
  end

  describe "execution receipt payload round-trip" do
    setup do
      infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      %{infra_key: infra_key, operator: operator, draw: executed}
    end

    test "execution receipt payload can be reconstructed from DB", %{
      draw: draw,
      infra_key: infra_key
    } do
      [exec_receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      decoded = Jason.decode!(exec_receipt.payload_jcs)

      # Schema version
      assert decoded["execution_schema_version"] == "1"

      # Draw fields match
      assert decoded["draw_id"] == draw.id
      assert decoded["operator_id"] == draw.operator_id
      assert decoded["seed"] == draw.seed
      assert decoded["drand_randomness"] == draw.drand_randomness

      # Results are flat entry_id strings in position order
      results = decoded["results"]
      assert is_list(results)
      assert Enum.all?(results, &is_binary/1)

      # Results match what we'd get from draw.results sorted by position
      expected_results =
        (draw.results || [])
        |> Enum.sort_by(fn r -> r["position"] end)
        |> Enum.map(fn r -> r["entry_id"] end)

      assert results == expected_results

      # lock_receipt_hash matches SHA-256 of the lock receipt
      [lock_receipt] =
        OperatorReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      expected_lock_hash =
        :crypto.hash(:sha256, lock_receipt.payload_jcs) |> Base.encode16(case: :lower)

      assert decoded["lock_receipt_hash"] == expected_lock_hash

      # Signature verifies
      assert Protocol.verify_receipt(
               exec_receipt.payload_jcs,
               exec_receipt.signature,
               infra_key.public_key
             )
    end

    test "entry_hash in execution receipt matches fresh recomputation", %{draw: draw} do
      [exec_receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      decoded = Jason.decode!(exec_receipt.payload_jcs)

      entries = WallopCore.Entries.load_for_draw(draw.id)
      {recomputed_hash, _} = Protocol.entry_hash(entries)
      assert decoded["entry_hash"] == recomputed_hash
    end
  end
end
