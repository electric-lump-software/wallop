defmodule WallopCore.ProtocolKeyRotationTest do
  @moduledoc """
  Regression test for operator key rotation (spec §4.2.4).

  Loads the cross-language vector at
  `spec/vectors/key-rotation-bidirectional.json` and asserts:

  1. **Historical receipts continue to verify forever.** A lock receipt
     signed during the pre-rotation key's active window verifies cleanly
     against that same key after rotation, because spec §4.2.4
     revocation is forward-only and the old key remains resolvable in
     the keyring.
  2. **New receipts verify against the new active key.** Post-rotation
     receipts signed with the new key check out.
  3. **Cross-key verifications fail.** A receipt signed by one key
     MUST NOT verify against any other key. Catches bugs where the
     resolver maps a receipt to the wrong keyring row, or where the
     pipeline drops the `key_id` check before signature verification.
  4. **`key_id` derivation is pinned byte-for-byte across
     implementations.** First 4 bytes of `SHA-256(public_key)`,
     lowercase hex.

  The same vector is consumed by `wallop_verifier` (Rust) — the test
  there asserts the identical four cases against the same recorded
  bytes. Cross-language parity holds across rotation if both
  implementations stay in lockstep on JCS canonicalisation, Ed25519
  primitive choice, and key_id derivation.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Protocol

  # Vector lives at the umbrella root. Same path-expansion pattern as
  # `proof_bundle_generator.exs` and `protocol_pin_vector_test.exs`.
  @vector_path Path.expand(
                 "../../../../spec/vectors/key-rotation-bidirectional.json",
                 __DIR__
               )

  setup_all do
    vector =
      @vector_path
      |> File.read!()
      |> Jason.decode!()

    {:ok, vector: vector}
  end

  describe "verifications block (the four cross-key cases)" do
    test "historical receipt continues to verify with original key", %{vector: vector} do
      assert run_case(vector, "historical receipt continues to verify with original key")
    end

    test "post-rotation receipt verifies with new key", %{vector: vector} do
      assert run_case(vector, "post-rotation receipt verifies with new key")
    end

    test "wrong-key — pre-rotation receipt against post-rotation key fails", %{vector: vector} do
      refute run_case(
               vector,
               "wrong-key — pre-rotation receipt against post-rotation key"
             )
    end

    test "wrong-key — post-rotation receipt against pre-rotation key fails", %{vector: vector} do
      refute run_case(
               vector,
               "wrong-key — post-rotation receipt against pre-rotation key"
             )
    end

    test "Ed25519 verify has no forward lower bound (pipeline temporal binding is separate)",
         %{vector: vector} do
      # Receipt is signed with the post-rotation key but its locked_at
      # predates that key's inserted_at. At the cryptographic primitive
      # level the signature is valid — the verifier MUST accept it here.
      # The pipeline-level temporal-binding step (spec §4.2.4) is the
      # separate layer that rejects such receipts; that's tested
      # elsewhere.
      assert run_case(vector, "Ed25519 verify itself has no forward lower bound")
    end
  end

  describe "key_id_derivation block" do
    test "every public key in the vector hashes to its recorded key_id", %{vector: vector} do
      checks = vector["key_id_derivation"]["checks"]

      Enum.each(checks, fn check ->
        public_key = Base.decode16!(check["public_key_hex"], case: :lower)
        derived = Protocol.key_id(public_key)

        assert derived == check["expected_key_id"],
               "public_key_hex #{check["public_key_hex"]} hashes to #{derived}, " <>
                 "vector records #{check["expected_key_id"]} — JCS / SHA-256 / hex casing drift"
      end)
    end

    test "key_id is exactly 8 lowercase hex characters", %{vector: vector} do
      checks = vector["key_id_derivation"]["checks"]

      Enum.each(checks, fn check ->
        assert String.match?(check["expected_key_id"], ~r/^[0-9a-f]{8}$/),
               "vector records non-canonical key_id: #{check["expected_key_id"]}"
      end)
    end
  end

  describe "vector self-consistency" do
    test "every signing_key referenced in receipts is defined in the keys block", %{
      vector: vector
    } do
      defined = vector["keys"] |> Map.keys() |> MapSet.new()

      Enum.each(vector["receipts"], fn {receipt_name, receipt} ->
        signing_key = receipt["signing_key"]

        assert MapSet.member?(defined, signing_key),
               "receipt #{receipt_name} references signing_key #{signing_key} which is not defined " <>
                 "in keys[]"
      end)
    end

    test "every verification case names a receipt and a key that both exist", %{vector: vector} do
      defined_receipts = vector["receipts"] |> Map.keys() |> MapSet.new()
      defined_keys = vector["keys"] |> Map.keys() |> MapSet.new()

      Enum.each(vector["verifications"], fn case_ ->
        assert MapSet.member?(defined_receipts, case_["receipt"]),
               "verification case #{case_["name"]} references unknown receipt #{case_["receipt"]}"

        assert MapSet.member?(defined_keys, case_["verify_against_key"]),
               "verification case #{case_["name"]} references unknown key #{case_["verify_against_key"]}"

        assert case_["expect"] in ["pass", "fail"],
               "verification case #{case_["name"]} has expect=#{case_["expect"]}, must be pass|fail"
      end)
    end

    test "the two keys have distinct key_ids (rotation must produce a new fingerprint)", %{
      vector: vector
    } do
      key_ids =
        vector["keys"]
        |> Map.values()
        |> Enum.map(& &1["key_id"])

      assert length(key_ids) == length(Enum.uniq(key_ids)),
             "rotation vector has duplicate key_ids: #{inspect(key_ids)}"
    end

    test "the two keys have distinct public_keys", %{vector: vector} do
      pks =
        vector["keys"]
        |> Map.values()
        |> Enum.map(& &1["public_key_hex"])

      assert length(pks) == length(Enum.uniq(pks)),
             "rotation vector has duplicate public keys"
    end
  end

  # Run a single verification case from the vector against `Protocol.verify_receipt/3`,
  # returning the boolean result. Tests above wrap with `assert` / `refute` per
  # the case's `expect` field.
  defp run_case(vector, case_name) do
    case_ =
      Enum.find(vector["verifications"], fn c -> c["name"] == case_name end) ||
        flunk("vector case not found: #{case_name}")

    receipt = vector["receipts"][case_["receipt"]]
    key = vector["keys"][case_["verify_against_key"]]

    payload = Base.decode16!(receipt["payload_jcs_hex"], case: :lower)
    signature = Base.decode16!(receipt["signature_hex"], case: :lower)
    public_key = Base.decode16!(key["public_key_hex"], case: :lower)

    Protocol.verify_receipt(payload, signature, public_key)
  end
end
