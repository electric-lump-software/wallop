defmodule WallopCore.ProtocolPinTest do
  use ExUnit.Case, async: true

  alias WallopCore.Protocol.Pin

  # Deterministic 32-byte test private key. Public/key_id derived
  # from it. NOT a real wallop infrastructure key.
  @test_private_key :crypto.hash(:sha256, "wallop-pin-test-private-seed")
  @test_public_key :crypto.generate_key(:eddsa, :ed25519, @test_private_key) |> elem(0)

  @published_at ~U[2026-04-29T19:36:58.252939Z]

  @keys [
    %{
      key_id: "21fe31df",
      public_key: :crypto.hash(:sha256, "operator-key-1") |> binary_part(0, 32)
    },
    %{
      key_id: "9d4a32b1",
      public_key: :crypto.hash(:sha256, "operator-key-2") |> binary_part(0, 32)
    },
    %{
      key_id: "c0ffee01",
      public_key: :crypto.hash(:sha256, "operator-key-3") |> binary_part(0, 32)
    }
  ]

  describe "constants" do
    test "schema_version is the literal string '1'" do
      assert Pin.schema_version() == "1"
    end

    test "domain_separator is exactly 'wallop-pin-v1\\n' (14 ASCII bytes)" do
      assert Pin.domain_separator() == "wallop-pin-v1\n"
      assert byte_size(Pin.domain_separator()) == 14

      assert Base.encode16(Pin.domain_separator(), case: :lower) ==
               "77616c6c6f702d70696e2d76310a"
    end
  end

  describe "build_payload/1" do
    test "produces JCS-canonical bytes with the four pre-image members" do
      {jcs, envelope} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: @keys,
          published_at: @published_at
        })

      assert is_binary(jcs)
      decoded = Jason.decode!(jcs)

      assert Map.keys(decoded) |> Enum.sort() ==
               ["keys", "operator_slug", "published_at", "schema_version"]

      assert decoded["schema_version"] == "1"
      assert decoded["operator_slug"] == "acme-prizes"
      assert decoded["published_at"] == "2026-04-29T19:36:58.252939Z"
      assert envelope == decoded
    end

    test "sorts keys[] ascending by key_id even when input is unsorted" do
      shuffled = Enum.reverse(@keys)

      {jcs, _envelope} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: shuffled,
          published_at: @published_at
        })

      decoded = Jason.decode!(jcs)
      assert Enum.map(decoded["keys"], & &1["key_id"]) == ["21fe31df", "9d4a32b1", "c0ffee01"]
    end

    test "every emitted row has exactly key_id / public_key_hex / key_class fields" do
      {jcs, _envelope} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: @keys,
          published_at: @published_at
        })

      decoded = Jason.decode!(jcs)

      Enum.each(decoded["keys"], fn row ->
        assert Map.keys(row) |> Enum.sort() == ["key_class", "key_id", "public_key_hex"]
        assert row["key_class"] == "operator"
        assert String.match?(row["public_key_hex"], ~r/^[0-9a-f]{64}$/)
      end)
    end

    test "raises on empty keys[]" do
      assert_raise ArgumentError, ~r/non-empty/, fn ->
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: [],
          published_at: @published_at
        })
      end
    end

    test "raises on malformed keyring row (missing public_key)" do
      assert_raise ArgumentError, ~r/invalid keyring row/, fn ->
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: [%{key_id: "deadbeef"}],
          published_at: @published_at
        })
      end
    end

    test "raises on malformed keyring row (wrong public_key length)" do
      assert_raise ArgumentError, ~r/invalid keyring row/, fn ->
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: [%{key_id: "deadbeef", public_key: <<1, 2, 3>>}],
          published_at: @published_at
        })
      end
    end

    test "produces byte-identical JCS for the same input regardless of map order" do
      same_keys_diff_order =
        Enum.map(@keys, fn k ->
          # Reverse map literal key order — Elixir maps don't preserve
          # but JCS must canonicalise anyway.
          %{public_key: k.public_key, key_id: k.key_id}
        end)

      {a, _} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: @keys,
          published_at: @published_at
        })

      {b, _} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: same_keys_diff_order,
          published_at: @published_at
        })

      assert a == b
    end
  end

  describe "sign/2 and verify/3" do
    test "round-trip succeeds with the matching public key" do
      {jcs, _envelope} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: @keys,
          published_at: @published_at
        })

      sig = Pin.sign(jcs, @test_private_key)
      assert byte_size(sig) == 64
      assert Pin.verify(jcs, sig, @test_public_key)
    end

    test "verify rejects a one-byte mutation of the pre-image" do
      {jcs, _envelope} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: @keys,
          published_at: @published_at
        })

      sig = Pin.sign(jcs, @test_private_key)

      <<head::binary-size(10), b, tail::binary>> = jcs
      mutated = head <> <<bxor(b, 1)>> <> tail

      refute Pin.verify(mutated, sig, @test_public_key)
    end

    test "verify rejects with a different public key" do
      {jcs, _envelope} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: @keys,
          published_at: @published_at
        })

      sig = Pin.sign(jcs, @test_private_key)

      other_priv = :crypto.hash(:sha256, "different-private-seed")
      {other_pub, _} = :crypto.generate_key(:eddsa, :ed25519, other_priv)

      refute Pin.verify(jcs, sig, other_pub)
    end

    test "domain separator is part of the signed bytes (raw JCS without prefix does NOT verify)" do
      {jcs, _envelope} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: @keys,
          published_at: @published_at
        })

      sig = Pin.sign(jcs, @test_private_key)

      # Verify against the raw JCS WITHOUT the domain separator using
      # crypto directly. Should fail because sign() prepended the
      # separator.
      refute :crypto.verify(:eddsa, :none, jcs, sig, [@test_public_key, :ed25519])
    end
  end

  describe "build_envelope/2" do
    test "appends infrastructure_signature as lowercase 128-character hex" do
      {_jcs, envelope} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: @keys,
          published_at: @published_at
        })

      sig = :crypto.strong_rand_bytes(64)
      wire = Pin.build_envelope(envelope, sig)

      assert wire["infrastructure_signature"] == Base.encode16(sig, case: :lower)
      assert String.match?(wire["infrastructure_signature"], ~r/^[0-9a-f]{128}$/)
      assert byte_size(wire["infrastructure_signature"]) == 128

      # The other four members are exactly the pre-image fields.
      assert Map.delete(wire, "infrastructure_signature") == envelope
    end
  end

  describe "verifier-style pre-image reconstruction" do
    test "stripping infrastructure_signature from a parsed envelope and re-canonicalising reproduces the signed bytes" do
      {jcs, envelope} =
        Pin.build_payload(%{
          operator_slug: "acme-prizes",
          keys: @keys,
          published_at: @published_at
        })

      sig = Pin.sign(jcs, @test_private_key)
      wire = Pin.build_envelope(envelope, sig)

      # Round-trip through JSON to mimic a verifier parsing the wire
      # bytes, then reconstruct the pre-image per spec §4.2.4.
      parsed = wire |> Jason.encode!() |> Jason.decode!()
      reconstructed = Map.delete(parsed, "infrastructure_signature") |> Jcs.encode()

      assert reconstructed == jcs
      assert Pin.verify(reconstructed, sig, @test_public_key)
    end
  end

  defp bxor(a, b), do: Bitwise.bxor(a, b)
end
