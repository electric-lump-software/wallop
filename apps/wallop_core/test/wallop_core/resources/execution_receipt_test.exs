defmodule WallopCore.Resources.ExecutionReceiptTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers
  require Ash.Query

  alias WallopCore.Protocol
  alias WallopCore.Resources.{ExecutionReceipt, InfrastructureSigningKey}

  describe "execution receipt creation (happy path)" do
    setup do
      infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      %{infra_key: infra_key, operator: operator, draw: executed}
    end

    test "creates an execution receipt in the same transaction as draw completion", %{
      draw: draw,
      infra_key: infra_key
    } do
      [receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      assert receipt.draw_id == draw.id
      assert receipt.operator_id == draw.operator_id
      assert receipt.sequence == draw.operator_sequence
      assert receipt.signing_key_id == infra_key.key_id
      assert byte_size(receipt.signature) == 64
      assert is_binary(receipt.payload_jcs)
      assert is_binary(receipt.lock_receipt_hash)
    end

    test "signature verifies under the infrastructure public key", %{
      draw: draw,
      infra_key: infra_key
    } do
      [receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      assert Protocol.verify_receipt(
               receipt.payload_jcs,
               receipt.signature,
               infra_key.public_key
             )
    end

    test "signature does NOT verify under a different key", %{draw: draw} do
      [receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      {wrong_pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)

      refute Protocol.verify_receipt(
               receipt.payload_jcs,
               receipt.signature,
               wrong_pub
             )
    end

    test "payload contains all required execution fields", %{draw: draw} do
      [receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      decoded = Jason.decode!(receipt.payload_jcs)

      # Receipt shape v4 — same 26 fields as v3; the bump is a coordination
      # flag for resolver-driven verification (spec §4.2.4).
      assert decoded["draw_id"] == draw.id
      assert decoded["operator_id"] == draw.operator_id
      assert is_integer(decoded["sequence"])
      assert decoded["schema_version"] == "4"
      assert is_binary(decoded["signing_key_id"])
      refute Map.has_key?(decoded, "execution_schema_version")
      assert decoded["jcs_version"] == "sha256-jcs-v1"
      assert decoded["signature_algorithm"] == "ed25519"
      assert decoded["entropy_composition"] == "drand-quicknet+openmeteo-v1"
      assert decoded["drand_signature_algorithm"] == "bls12_381_g2"
      assert decoded["merkle_algorithm"] == "sha256-pairwise-v1"

      # Entropy fields
      assert decoded["drand_randomness"] == test_drand_randomness()
      assert decoded["drand_signature"] == "test-signature"
      assert is_binary(decoded["seed"])
      assert is_list(decoded["results"])

      # Lock receipt linkage
      assert String.match?(decoded["lock_receipt_hash"], ~r/^[0-9a-f]{64}$/)

      # Algorithm versions
      assert is_binary(decoded["wallop_core_version"])
      assert is_binary(decoded["fair_pick_version"])

      # Execution timestamp
      assert is_binary(decoded["executed_at"])

      # Entry hash (self-contained verification)
      assert decoded["entry_hash"] == draw.entry_hash
    end

    test "lock_receipt_hash matches SHA-256 of the lock receipt payload", %{draw: draw} do
      [exec_receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      [lock_receipt] =
        WallopCore.Resources.OperatorReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      expected_hash =
        :crypto.hash(:sha256, lock_receipt.payload_jcs) |> Base.encode16(case: :lower)

      decoded = Jason.decode!(exec_receipt.payload_jcs)
      assert decoded["lock_receipt_hash"] == expected_hash
      assert exec_receipt.lock_receipt_hash == expected_hash
    end

    test "results are a flat list of entry UUIDs in position order", %{draw: draw} do
      [receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      decoded = Jason.decode!(receipt.payload_jcs)
      results = decoded["results"]

      assert is_list(results)
      assert length(results) == draw.winner_count
      assert Enum.all?(results, &is_binary/1)

      uuid_regex = ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
      assert Enum.all?(results, &String.match?(&1, uuid_regex))

      entry_uuids = WallopCore.Entries.load_for_draw(draw.id) |> Enum.map(& &1.uuid)
      assert Enum.all?(results, fn r -> r in entry_uuids end)
    end

    test "payload JCS keys are sorted (canonical JSON)" do
      infra_key = create_infrastructure_key()
      _ = infra_key
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      [receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^executed.id)
        |> Ash.read!(authorize?: false)

      # JCS requires lexicographic key ordering
      decoded_keys = receipt.payload_jcs |> Jason.decode!() |> Map.keys()
      assert decoded_keys == Enum.sort(decoded_keys)
    end
  end

  describe "execution receipt — no operator rejected" do
    test "draw creation is rejected for API keys without an operator" do
      api_key =
        WallopCore.Resources.ApiKey
        |> Ash.Changeset.for_create(:create, %{name: "orphan-key"})
        |> Ash.create!(authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               WallopCore.Resources.Draw
               |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
               |> Ash.create()
    end
  end

  describe "execution receipt — no infrastructure key" do
    test "draw execution fails with clear error when infra key is missing" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)

      # Transition to pending manually (bypassing execute_draw which auto-creates infra key)
      draw =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      # No infra key bootstrapped — execution should fail
      assert {:error, _} =
               draw
               |> Ash.Changeset.for_update(:execute_with_entropy, %{
                 drand_randomness: test_drand_randomness(),
                 drand_signature: "test-signature",
                 drand_response: "{}",
                 weather_value: "12.3",
                 weather_raw: "{}",
                 weather_observation_time: DateTime.add(draw.inserted_at, 1, :second)
               })
               |> Ash.update(domain: WallopCore.Domain, authorize?: false)
    end
  end

  describe "execution receipt — unique_draw identity" do
    setup do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      %{draw: executed}
    end

    test "cannot insert a second execution receipt for the same draw", %{draw: draw} do
      assert {:error, _} =
               ExecutionReceipt
               |> Ash.Changeset.for_create(:create, %{
                 draw_id: draw.id,
                 operator_id: draw.operator_id,
                 sequence: draw.operator_sequence,
                 lock_receipt_hash: "duplicate",
                 payload_jcs: "duplicate",
                 signature: :crypto.strong_rand_bytes(64),
                 signing_key_id: "dup"
               })
               |> Ash.create(authorize?: false)
    end
  end

  describe "execution receipt — append-only (DB trigger)" do
    setup do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      %{draw: executed}
    end

    test "cannot UPDATE execution_receipts via raw SQL", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/execution_receipts is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE execution_receipts SET sequence = 999 WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "cannot DELETE execution_receipts via raw SQL", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/execution_receipts is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM execution_receipts WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  describe "execution receipt — key rotation" do
    test "uses the most recent infra key by valid_from" do
      # Insert an "older" key. Offset stays inside the ±60s skew window
      # enforced by the keyring temporal binding CHECK; the helper-created
      # newer key (-30s) still has a strictly later valid_from than this
      # one (-45s), which is what the rotation pick logic actually tests.
      {old_pub, old_priv} = :crypto.generate_key(:eddsa, :ed25519)
      old_key_id = Protocol.key_id(old_pub)
      {:ok, old_encrypted} = WallopCore.Vault.encrypt(old_priv)

      {:ok, _old_key} =
        InfrastructureSigningKey
        |> Ash.Changeset.for_create(:create, %{
          key_id: old_key_id,
          public_key: old_pub,
          private_key: old_encrypted,
          valid_from: DateTime.add(DateTime.utc_now(), -45, :second)
        })
        |> Ash.create(authorize?: false)

      # Insert a newer key
      new_key = create_infrastructure_key()

      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      [receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^executed.id)
        |> Ash.read!(authorize?: false)

      # Should have used the newer key
      assert receipt.signing_key_id == new_key.key_id

      # Verify against the new key's public key, not the old one
      assert Protocol.verify_receipt(receipt.payload_jcs, receipt.signature, new_key.public_key)
      refute Protocol.verify_receipt(receipt.payload_jcs, receipt.signature, old_pub)
    end

    test "ignores infra keys with valid_from in the future" do
      # Insert a current key
      current_key = create_infrastructure_key()

      # Insert a future-dated key. Offset stays inside the ±60s skew
      # window enforced by the keyring temporal binding CHECK; what's
      # being tested here is the rotation pick's `valid_from <= now`
      # filter, not arbitrary forward-dating (which the CHECK rejects
      # at insert time anyway).
      {future_pub, future_priv} = :crypto.generate_key(:eddsa, :ed25519)
      future_key_id = Protocol.key_id(future_pub)
      {:ok, future_encrypted} = WallopCore.Vault.encrypt(future_priv)

      {:ok, _future_key} =
        InfrastructureSigningKey
        |> Ash.Changeset.for_create(:create, %{
          key_id: future_key_id,
          public_key: future_pub,
          private_key: future_encrypted,
          valid_from: DateTime.add(DateTime.utc_now(), 45, :second)
        })
        |> Ash.create(authorize?: false)

      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      [receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^executed.id)
        |> Ash.read!(authorize?: false)

      assert receipt.signing_key_id == current_key.key_id
    end
  end

  describe "execution receipt — multiple draws" do
    setup do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      %{operator: operator, api_key: api_key}
    end

    test "each draw gets its own execution receipt with correct sequence", %{api_key: api_key} do
      d1 = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))
      d2 = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))
      d3 = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))

      receipts =
        ExecutionReceipt
        |> Ash.Query.sort(sequence: :asc)
        |> Ash.read!(authorize?: false)

      assert length(receipts) == 3
      assert Enum.map(receipts, & &1.sequence) == [1, 2, 3]
      assert Enum.map(receipts, & &1.draw_id) == [d1.id, d2.id, d3.id]
    end
  end

  describe "execution receipt — drand-only fallback" do
    test "creates execution receipt for drand-only draws with weather fields null" do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)

      # Transition to pending
      draw =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      # Execute drand-only (no weather)
      executed =
        draw
        |> Ash.Changeset.for_update(:execute_drand_only, %{
          drand_randomness: test_drand_randomness(),
          drand_signature: "test-bls-sig",
          drand_response: "{}",
          weather_fallback_reason: "unreachable"
        })
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      [receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^executed.id)
        |> Ash.read!(authorize?: false)

      decoded = Jason.decode!(receipt.payload_jcs)

      # Weather value/observation should be null (weather fetch failed)
      assert decoded["weather_value"] == nil
      assert decoded["weather_observation_time"] == nil

      # Station is still declared at lock time (before fetch attempt)
      assert is_binary(decoded["weather_station"])

      # Fallback reason should be present
      assert decoded["weather_fallback_reason"] == "unreachable"

      # Drand fields should be populated
      assert decoded["drand_randomness"] == test_drand_randomness()
      assert decoded["drand_signature"] == "test-bls-sig"

      # Schema version
      assert decoded["schema_version"] == "4"
      assert is_binary(decoded["signing_key_id"])
      refute Map.has_key?(decoded, "execution_schema_version")
    end
  end
end
