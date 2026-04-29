defmodule WallopCore.ProtocolPinVectorTest do
  @moduledoc """
  Cross-language conformance regression for the signed keyring pin
  (spec §4.2.4).

  This test loads the canonical vector at `spec/vectors/pin/v1/valid.json`
  and asserts:

  1. Reconstructing the pre-image from the envelope (parse, drop
     `infrastructure_signature`, JCS-canonicalise) yields exactly the
     bytes recorded in `preimage_jcs_hex`. Catches any drift in the JCS
     canonicalisation path.
  2. Re-signing the pre-image with the recorded private key produces the
     `expected_signature_hex` byte-for-byte. Catches any drift in the
     domain-separator prepending or the Ed25519 sign call.
  3. Verifying the recorded signature against the recorded public key
     succeeds.
  4. Verifying the recorded signature against the mutated pre-image fails.

  If any of these assertions break, either the vector is wrong or the
  Elixir implementation has drifted from the spec. The vector also
  ships to `wallop_verifier` (Rust) — both languages must agree
  byte-for-byte.
  """
  use ExUnit.Case, async: true

  alias WallopCore.Protocol.Pin

  # Vector lives at the umbrella root; this test file is nested four
  # levels deep inside `apps/wallop_core/test/wallop_core/`.
  @vector_path Path.expand("../../../../spec/vectors/pin/v1/valid.json", __DIR__)

  setup_all do
    vector =
      @vector_path
      |> File.read!()
      |> Jason.decode!()

    {:ok, vector: vector}
  end

  test "domain separator in vector matches the module's frozen value", %{vector: vector} do
    assert Base.decode16!(vector["domain_separator_hex"], case: :lower) == Pin.domain_separator()
  end

  test "valid vector: pre-image reconstructs from envelope byte-identical to recorded preimage_jcs_hex",
       %{vector: vector} do
    valid = Enum.find(vector["vectors"], &(&1["name"] == "valid sign + verify"))

    reconstructed =
      valid["envelope"]
      |> Map.delete("infrastructure_signature")
      |> Jcs.encode()

    expected = Base.decode16!(valid["preimage_jcs_hex"], case: :lower)
    assert reconstructed == expected
  end

  test "valid vector: re-signing the pre-image with the recorded private key produces the recorded signature",
       %{vector: vector} do
    valid = Enum.find(vector["vectors"], &(&1["name"] == "valid sign + verify"))

    private_key = Base.decode16!(vector["infrastructure_keypair"]["private_key_hex"], case: :lower)
    preimage = Base.decode16!(valid["preimage_jcs_hex"], case: :lower)
    expected_sig = Base.decode16!(valid["expected_signature_hex"], case: :lower)

    actual_sig = Pin.sign(preimage, private_key)
    assert actual_sig == expected_sig
  end

  test "valid vector: signature verifies against the recorded public key", %{vector: vector} do
    valid = Enum.find(vector["vectors"], &(&1["name"] == "valid sign + verify"))

    public_key = Base.decode16!(vector["infrastructure_keypair"]["public_key_hex"], case: :lower)
    preimage = Base.decode16!(valid["preimage_jcs_hex"], case: :lower)
    sig = Base.decode16!(valid["expected_signature_hex"], case: :lower)

    assert Pin.verify(preimage, sig, public_key)
  end

  test "negative vector: signature does NOT verify against the mutated pre-image", %{
    vector: vector
  } do
    mutated = Enum.find(vector["vectors"], &(&1["name"] == "single-byte mutation rejects"))

    public_key = Base.decode16!(vector["infrastructure_keypair"]["public_key_hex"], case: :lower)
    mutated_preimage = Base.decode16!(mutated["preimage_jcs_hex"], case: :lower)
    sig = Base.decode16!(mutated["signature_hex"], case: :lower)

    refute Pin.verify(mutated_preimage, sig, public_key)
  end

  test "envelope schema_version is the literal '1'", %{vector: vector} do
    valid = Enum.find(vector["vectors"], &(&1["name"] == "valid sign + verify"))
    assert valid["envelope"]["schema_version"] == "1"
  end

  test "every keys[] row carries exactly key_id / public_key_hex / key_class with key_class == 'operator'",
       %{vector: vector} do
    valid = Enum.find(vector["vectors"], &(&1["name"] == "valid sign + verify"))

    Enum.each(valid["envelope"]["keys"], fn row ->
      assert Map.keys(row) |> Enum.sort() == ["key_class", "key_id", "public_key_hex"]
      assert row["key_class"] == "operator"
      assert String.match?(row["key_id"], ~r/^[0-9a-f]{8}$/)
      assert String.match?(row["public_key_hex"], ~r/^[0-9a-f]{64}$/)
    end)
  end
end
