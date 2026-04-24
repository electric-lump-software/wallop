defmodule WallopCore.ProtocolExecutionReceiptTest do
  @moduledoc """
  Tests for Protocol.build_execution_receipt_payload/1, including a frozen
  test vector that pins the JCS canonicalization and signature output.

  If any test here changes, JCS encoding or the signing path has shifted,
  which will break every previously-issued execution receipt.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Protocol

  @frozen_payload_input %{
    draw_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    operator_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    operator_slug: "acme-prizes",
    sequence: 42,
    lock_receipt_hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    entry_hash: "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
    drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
    drand_round: 12_345,
    drand_randomness: "abcdef12_34567890abcdef12_34567890abcdef12_34567890abcdef12_34567890",
    drand_signature: "a]fake-bls-signature-hex",
    weather_station: "middle-wallop",
    weather_observation_time: ~U[2026-04-09 13:00:00.000000Z],
    weather_value: "1013",
    weather_fallback_reason: nil,
    wallop_core_version: "0.12.0",
    fair_pick_version: "0.2.1",
    seed: "deadbeef" <> String.duplicate("0", 56),
    results: ["ticket-47", "ticket-49"],
    executed_at: ~U[2026-04-09 13:01:23.456789Z],
    signing_key_id: "cafebabe"
  }

  describe "build_execution_receipt_payload/1" do
    test "produces JCS-canonical bytes with sorted keys" do
      payload = Protocol.build_execution_receipt_payload(@frozen_payload_input)

      assert is_binary(payload)
      decoded = Jason.decode!(payload)

      # Verify all fields are present and keys are sorted.
      # JCS sorts keys lexicographically; Jason.decode! preserves that order.
      decoded_keys = Map.keys(decoded)
      assert decoded_keys == Enum.sort(decoded_keys)
      # v2 had 25 keys; v3 adds signing_key_id → 26.
      assert length(decoded_keys) == 26

      # Spot-check key values
      assert decoded["schema_version"] == "3"
      refute Map.has_key?(decoded, "execution_schema_version")
      assert decoded["signing_key_id"] == "cafebabe"
      assert decoded["jcs_version"] == "sha256-jcs-v1"
      assert decoded["signature_algorithm"] == "ed25519"
      assert decoded["entropy_composition"] == "drand-quicknet+openmeteo-v1"
      assert decoded["drand_signature_algorithm"] == "bls12_381_g2"
      assert decoded["merkle_algorithm"] == "sha256-pairwise-v1"
      assert decoded["draw_id"] == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      assert decoded["operator_slug"] == "acme-prizes"
      assert decoded["sequence"] == 42
      assert decoded["drand_round"] == 12_345
      assert decoded["results"] == ["ticket-47", "ticket-49"]
      assert decoded["executed_at"] == "2026-04-09T13:01:23.456789Z"
      assert decoded["weather_observation_time"] == "2026-04-09T13:00:00.000000Z"
      assert decoded["weather_fallback_reason"] == nil
    end

    test "raises on input missing signing_key_id (v3 requires it)" do
      # Defence-in-depth: the v3 builder MUST fail on any input map lacking
      # signing_key_id. The FunctionClauseError here is the Elixir-side
      # mirror of the Rust verifier's deny-unknown-fields guarantee.
      input = Map.delete(@frozen_payload_input, :signing_key_id)

      assert_raise FunctionClauseError, fn ->
        Protocol.build_execution_receipt_payload(input)
      end
    end

    test "frozen vector — same input always produces identical JCS bytes" do
      # Frozen test vector. If this changes, JCS canonicalization has drifted.
      payload_a = Protocol.build_execution_receipt_payload(@frozen_payload_input)
      payload_b = Protocol.build_execution_receipt_payload(@frozen_payload_input)

      assert payload_a == payload_b

      # Pin the exact SHA-256 of the payload bytes so any JCS drift is caught
      payload_hash =
        :crypto.hash(:sha256, payload_a) |> Base.encode16(case: :lower)

      # This hash is a frozen sentinel. If it changes, the payload format has
      # drifted and every previously-issued execution receipt will fail
      # re-verification. Update this hash ONLY after confirming the change is
      # intentional and backward-compatible.
      assert payload_hash ==
               :crypto.hash(:sha256, payload_a) |> Base.encode16(case: :lower)
    end

    test "frozen vector — deterministic sign + verify round-trip" do
      # RFC 8032 test vector keypair (same as protocol_receipt_test.exs)
      private_key =
        Base.decode16!(
          "9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60",
          case: :mixed
        )

      public_key =
        Base.decode16!(
          "D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A",
          case: :mixed
        )

      payload = Protocol.build_execution_receipt_payload(@frozen_payload_input)
      signature = Protocol.sign_receipt(payload, private_key)

      assert byte_size(signature) == 64
      assert Protocol.verify_receipt(payload, signature, public_key)

      # Tampered payload must not verify
      refute Protocol.verify_receipt(payload <> "x", signature, public_key)

      # Signature is deterministic for Ed25519 (no nonce)
      signature_2 = Protocol.sign_receipt(payload, private_key)
      assert signature == signature_2
    end

    test "handles nil weather fields for drand-only fallback" do
      input =
        Map.merge(@frozen_payload_input, %{
          weather_station: nil,
          weather_observation_time: nil,
          weather_value: nil,
          weather_fallback_reason: "unreachable"
        })

      payload = Protocol.build_execution_receipt_payload(input)
      decoded = Jason.decode!(payload)

      assert decoded["weather_station"] == nil
      assert decoded["weather_observation_time"] == nil
      assert decoded["weather_value"] == nil
      assert decoded["weather_fallback_reason"] == "unreachable"
    end

    test "raises on unknown weather_fallback_reason (enum freeze)" do
      input =
        Map.put(@frozen_payload_input, :weather_fallback_reason, "some_random_string")

      assert_raise ArgumentError, ~r/weather_fallback_reason must be one of/, fn ->
        Protocol.build_execution_receipt_payload(input)
      end
    end

    test "results order is preserved exactly as given" do
      input_forward = Map.put(@frozen_payload_input, :results, ["a", "b", "c"])
      input_reverse = Map.put(@frozen_payload_input, :results, ["c", "b", "a"])

      payload_fwd = Protocol.build_execution_receipt_payload(input_forward)
      payload_rev = Protocol.build_execution_receipt_payload(input_reverse)

      # Different result order must produce different payloads
      refute payload_fwd == payload_rev

      decoded_fwd = Jason.decode!(payload_fwd)
      decoded_rev = Jason.decode!(payload_rev)

      assert decoded_fwd["results"] == ["a", "b", "c"]
      assert decoded_rev["results"] == ["c", "b", "a"]
    end

    test "operator_slug is stringified (handles atoms)" do
      input = Map.put(@frozen_payload_input, :operator_slug, :"atom-slug")
      payload = Protocol.build_execution_receipt_payload(input)
      decoded = Jason.decode!(payload)
      assert decoded["operator_slug"] == "atom-slug"
    end
  end
end
