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

  # Vector lives at the umbrella root. Same path-expansion pattern as
  # `proof_bundle_generator.exs` and `vectors_regenerator.exs`.
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
    valid = find_vector(vector, "valid sign + verify")

    reconstructed =
      valid["envelope"]
      |> Map.delete("infrastructure_signature")
      |> Jcs.encode()

    expected = Base.decode16!(valid["preimage_jcs_hex"], case: :lower)
    assert reconstructed == expected
  end

  test "valid vector: re-signing the pre-image with the recorded private key produces the recorded signature",
       %{vector: vector} do
    valid = find_vector(vector, "valid sign + verify")

    private_key =
      Base.decode16!(vector["infrastructure_keypair"]["private_key_hex"], case: :lower)

    preimage = Base.decode16!(valid["preimage_jcs_hex"], case: :lower)
    expected_sig = Base.decode16!(valid["expected_signature_hex"], case: :lower)

    actual_sig = Pin.sign(preimage, private_key)
    assert actual_sig == expected_sig
  end

  test "valid vector: signature verifies against the recorded public key", %{vector: vector} do
    valid = find_vector(vector, "valid sign + verify")

    public_key = Base.decode16!(vector["infrastructure_keypair"]["public_key_hex"], case: :lower)
    preimage = Base.decode16!(valid["preimage_jcs_hex"], case: :lower)
    sig = Base.decode16!(valid["expected_signature_hex"], case: :lower)

    assert Pin.verify(preimage, sig, public_key)
  end

  test "negative vector: single-byte preimage mutation does NOT verify", %{vector: vector} do
    mutated = find_vector(vector, "single-byte preimage mutation rejects")

    public_key = Base.decode16!(vector["infrastructure_keypair"]["public_key_hex"], case: :lower)
    mutated_preimage = Base.decode16!(mutated["preimage_jcs_hex"], case: :lower)
    sig = Base.decode16!(mutated["signature_hex"], case: :lower)

    refute Pin.verify(mutated_preimage, sig, public_key)
  end

  test "negative vector: single-byte signature mutation does NOT verify", %{vector: vector} do
    mutated = find_vector(vector, "single-byte signature mutation rejects")

    public_key = Base.decode16!(vector["infrastructure_keypair"]["public_key_hex"], case: :lower)
    preimage = Base.decode16!(mutated["preimage_jcs_hex"], case: :lower)
    mutated_sig = Base.decode16!(mutated["signature_hex"], case: :lower)

    refute Pin.verify(preimage, mutated_sig, public_key)
  end

  test "negative vector: wrong-key signature does NOT verify against the recorded public key",
       %{vector: vector} do
    wrong = find_vector(vector, "wrong key rejects")

    # Sanity: vector targets the recorded infrastructure public key, not
    # the wrong keypair's. The wrong sig was produced by a *different*
    # private key, so verification against this public key MUST fail.
    public_key = Base.decode16!(wrong["verify_against_public_key_hex"], case: :lower)
    preimage = Base.decode16!(wrong["preimage_jcs_hex"], case: :lower)
    sig = Base.decode16!(wrong["signature_hex"], case: :lower)

    assert public_key ==
             Base.decode16!(vector["infrastructure_keypair"]["public_key_hex"], case: :lower)

    refute Pin.verify(preimage, sig, public_key)
  end

  test "negative vector: domain-separator-omitted signature does NOT verify", %{vector: vector} do
    # Catches the most likely cross-language bug — implementer reads
    # "Ed25519(payload)" and forgets to prepend the 14-byte domain
    # separator before signing.
    omitted = find_vector(vector, "domain-separator-omitted rejects")

    public_key = Base.decode16!(vector["infrastructure_keypair"]["public_key_hex"], case: :lower)
    preimage = Base.decode16!(omitted["preimage_jcs_hex"], case: :lower)
    sig = Base.decode16!(omitted["signature_hex"], case: :lower)

    # Pin.verify prepends the domain separator and MUST reject the
    # signature that was produced over the raw JCS without it.
    refute Pin.verify(preimage, sig, public_key)
  end

  test "sort normalisation: building a payload from reversed input yields byte-identical JCS",
       %{vector: vector} do
    # The producer MUST sort `keys[]` ascending by `key_id` regardless of
    # input order. Catches a Rust producer that forgets to normalise.
    sort_case = find_vector(vector, "reversed-input key sort normalised by producer")

    expected = Base.decode16!(sort_case["expected_preimage_jcs_hex"], case: :lower)

    keys =
      Enum.map(sort_case["input_keys_in_order"], fn k ->
        %{
          key_id: k["key_id"],
          public_key: Base.decode16!(k["public_key_hex"], case: :lower)
        }
      end)

    valid = find_vector(vector, "valid sign + verify")

    {actual, _} =
      Pin.build_payload(%{
        operator_slug: valid["envelope"]["operator_slug"],
        keys: keys,
        published_at: parse_published_at(valid["envelope"]["published_at"])
      })

    assert actual == expected
  end

  test "envelope schema_version is the literal '1'", %{vector: vector} do
    valid = find_vector(vector, "valid sign + verify")
    assert valid["envelope"]["schema_version"] == "1"
  end

  test "every keys[] row carries exactly key_id / public_key_hex / key_class with key_class == 'operator'",
       %{vector: vector} do
    valid = find_vector(vector, "valid sign + verify")

    Enum.each(valid["envelope"]["keys"], fn row ->
      assert Map.keys(row) |> Enum.sort() == ["key_class", "key_id", "public_key_hex"]
      assert row["key_class"] == "operator"
      assert String.match?(row["key_id"], ~r/^[0-9a-f]{8}$/)
      assert String.match?(row["public_key_hex"], ~r/^[0-9a-f]{64}$/)
    end)
  end

  defp find_vector(vector, name) do
    case Enum.find(vector["vectors"], &(&1["name"] == name)) do
      nil ->
        flunk(
          "vector named #{inspect(name)} not found in #{@vector_path}; " <>
            "available: #{inspect(Enum.map(vector["vectors"], & &1["name"]))}"
        )

      v ->
        v
    end
  end

  defp parse_published_at(s) do
    {:ok, dt, _} = DateTime.from_iso8601(s)
    dt
  end
end
