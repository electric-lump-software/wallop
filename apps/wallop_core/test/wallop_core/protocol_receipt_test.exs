defmodule WallopCore.ProtocolReceiptTest do
  use ExUnit.Case, async: true

  alias WallopCore.Protocol

  describe "build_receipt_payload/1" do
    test "produces JCS-canonical bytes with sorted keys (schema v2)" do
      payload =
        Protocol.build_receipt_payload(%{
          operator_id: "11111111-1111-1111-1111-111111111111",
          operator_slug: "acme-prizes",
          sequence: 42,
          draw_id: "22222222-2222-2222-2222-222222222222",
          commitment_hash: "abc",
          entry_hash: "abc",
          locked_at: ~U[2026-04-07 12:34:56.789012Z],
          signing_key_id: "deadbeef",
          winner_count: 3,
          drand_chain: "quicknet-chain-hash",
          drand_round: 12_345,
          weather_station: "middle-wallop",
          weather_time: ~U[2026-04-07 13:00:00.000000Z],
          wallop_core_version: "0.11.2",
          fair_pick_version: "0.2.1"
        })

      assert is_binary(payload)
      decoded = Jason.decode!(payload)

      assert decoded == %{
               "commitment_hash" => "abc",
               "draw_id" => "22222222-2222-2222-2222-222222222222",
               "drand_chain" => "quicknet-chain-hash",
               "drand_round" => 12_345,
               "entry_hash" => "abc",
               "fair_pick_version" => "0.2.1",
               "locked_at" => "2026-04-07T12:34:56.789012Z",
               "operator_id" => "11111111-1111-1111-1111-111111111111",
               "operator_slug" => "acme-prizes",
               "schema_version" => "2",
               "sequence" => 42,
               "signing_key_id" => "deadbeef",
               "wallop_core_version" => "0.11.2",
               "weather_station" => "middle-wallop",
               "weather_time" => "2026-04-07T13:00:00.000000Z",
               "winner_count" => 3
             }
    end

    test "handles nil weather fields for caller-seed draws" do
      payload =
        Protocol.build_receipt_payload(%{
          operator_id: "11111111-1111-1111-1111-111111111111",
          operator_slug: "acme-prizes",
          sequence: 1,
          draw_id: "33333333-3333-3333-3333-333333333333",
          commitment_hash: "def",
          entry_hash: "def",
          locked_at: ~U[2026-04-07 12:00:00.000000Z],
          signing_key_id: "cafebabe",
          winner_count: 1,
          drand_chain: nil,
          drand_round: nil,
          weather_station: nil,
          weather_time: nil,
          wallop_core_version: "0.11.2",
          fair_pick_version: "0.2.1"
        })

      decoded = Jason.decode!(payload)
      assert decoded["drand_chain"] == nil
      assert decoded["drand_round"] == nil
      assert decoded["weather_station"] == nil
      assert decoded["weather_time"] == nil
      assert decoded["winner_count"] == 1
      assert decoded["schema_version"] == "2"
    end
  end

  describe "sign_receipt/2 + verify_receipt/3" do
    test "round-trips with a freshly generated keypair" do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      payload = "the canonical bytes"
      signature = Protocol.sign_receipt(payload, priv)

      assert byte_size(signature) == 64
      assert Protocol.verify_receipt(payload, signature, pub)
      refute Protocol.verify_receipt("tampered", signature, pub)
    end

    test "test vector — fixed key produces a fixed signature" do
      # Frozen test vector. If this changes, JCS canonicalization or sign_receipt
      # has shifted, which will break every previously-issued receipt.
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

      payload = ~s({"hello":"world"})
      signature = Protocol.sign_receipt(payload, private_key)

      assert Protocol.verify_receipt(payload, signature, public_key)
      assert byte_size(signature) == 64
    end
  end

  describe "key_id/1" do
    test "returns first 8 lowercase hex chars of sha256(public_key)" do
      {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)
      id = Protocol.key_id(pub)
      assert String.length(id) == 8
      assert String.match?(id, ~r/^[0-9a-f]{8}$/)
    end
  end

  describe "merkle_root/1" do
    test "empty list → sha256(<<>>)" do
      assert Protocol.merkle_root([]) == :crypto.hash(:sha256, <<>>)
    end

    test "single leaf → sha256(<<0>> <> leaf)" do
      leaf = "abc"
      expected = :crypto.hash(:sha256, <<0>> <> leaf)
      assert Protocol.merkle_root([leaf]) == expected
    end

    test "two leaves → internal node" do
      a = "a"
      b = "b"
      ha = :crypto.hash(:sha256, <<0, ?a>>)
      hb = :crypto.hash(:sha256, <<0, ?b>>)
      expected = :crypto.hash(:sha256, <<1>> <> ha <> hb)
      assert Protocol.merkle_root([a, b]) == expected
    end

    test "odd-length levels duplicate the last node" do
      root = Protocol.merkle_root(["a", "b", "c"])
      assert byte_size(root) == 32
    end

    test "deterministic for the same input" do
      input = Enum.map(1..16, &Integer.to_string/1)
      assert Protocol.merkle_root(input) == Protocol.merkle_root(input)
    end
  end
end
