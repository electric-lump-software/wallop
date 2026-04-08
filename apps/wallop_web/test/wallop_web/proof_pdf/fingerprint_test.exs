defmodule WallopWeb.ProofPdf.FingerprintTest do
  use ExUnit.Case, async: true

  alias WallopWeb.ProofPdf.Fingerprint

  describe "build/4" do
    test "produces a fingerprint with all expected keys" do
      fp = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt(), fixed_now())

      assert fp |> Map.keys() |> Enum.sort() == [
               "drand_chain",
               "drand_randomness",
               "drand_round",
               "draw_id",
               "entry_hash",
               "generated_at",
               "operator_id",
               "operator_sequence",
               "operator_slug",
               "receipt",
               "schema_version",
               "seed",
               "template_revision",
               "weather_observation_time",
               "weather_value",
               "winners"
             ]
    end

    test "operator_slug is a plain string, not a CiString struct" do
      fp = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt())
      assert fp["operator_slug"] == "acme-prizes"
      assert is_binary(fp["operator_slug"])
    end

    test "winners normalised to {position, entry_id} string-keyed maps" do
      fp = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt())

      assert fp["winners"] == [
               %{"position" => 1, "entry_id" => "ticket-47"},
               %{"position" => 2, "entry_id" => "ticket-12"}
             ]
    end

    test "receipt block base64-encodes the binary fields" do
      fp = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt())

      assert fp["receipt"] == %{
               "sequence" => 7,
               "signing_key_id" => "abcd1234",
               "locked_at" => "2026-04-01T10:00:00.000000Z",
               "payload_jcs_b64" => Base.encode64("payload-jcs-bytes"),
               "signature_b64" => Base.encode64("signature-bytes")
             }
    end

    test "operator and receipt may be nil (backward compat)" do
      fp = Fingerprint.build(sample_draw(), nil, nil, fixed_now())
      assert fp["operator_slug"] == nil
      assert fp["operator_id"] == nil
      assert fp["receipt"] == nil
    end

    test "weather fields may be nil (drand-only fallback)" do
      draw = %{sample_draw() | weather_observation_time: nil, weather_value: nil}
      fp = Fingerprint.build(draw, sample_operator(), sample_receipt())
      assert fp["weather_observation_time"] == nil
      assert fp["weather_value"] == nil
    end
  end

  describe "encode/1" do
    test "produces stable JCS-canonical bytes (frozen test vector)" do
      fp = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt(), fixed_now())
      encoded = Fingerprint.encode(fp)

      # Frozen test vector. If this changes, every previously-issued
      # fingerprint becomes incompatible — bump schema_version when
      # the shape changes deliberately, never silently.
      assert encoded ==
               ~s|{"drand_chain":"chain-hash","drand_randomness":"randomness-hex","drand_round":12345,"draw_id":"00000000-0000-0000-0000-000000000001","entry_hash":"entry-hash-hex","generated_at":"2026-04-08T12:00:00.000000Z","operator_id":"00000000-0000-0000-0000-000000000002","operator_sequence":42,"operator_slug":"acme-prizes","receipt":{"locked_at":"2026-04-01T10:00:00.000000Z","payload_jcs_b64":"cGF5bG9hZC1qY3MtYnl0ZXM=","sequence":7,"signature_b64":"c2lnbmF0dXJlLWJ5dGVz","signing_key_id":"abcd1234"},"schema_version":"1","seed":"seed-hex","template_revision":"1","weather_observation_time":"2026-04-08T11:00:00.000000Z","weather_value":"12.3","winners":[{"entry_id":"ticket-47","position":1},{"entry_id":"ticket-12","position":2}]}|
    end
  end

  describe "build → encode → decode → compare round-trip" do
    test "round-trip preserves equivalence under compare/2" do
      fp = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt(), fixed_now())
      encoded = Fingerprint.encode(fp)

      {:ok, decoded} = Jason.decode(encoded)

      assert :ok = Fingerprint.compare(fp, decoded)
      assert :ok = Fingerprint.compare(decoded, fp)
    end

    test "round-trip with operator/receipt nil" do
      fp = Fingerprint.build(sample_draw(), nil, nil, fixed_now())
      encoded = Fingerprint.encode(fp)
      {:ok, decoded} = Jason.decode(encoded)
      assert :ok = Fingerprint.compare(fp, decoded)
    end
  end

  describe "winners ordering" do
    test "normalised winners are sorted by position" do
      draw =
        sample_draw()
        |> Map.put(:results, [
          %{"position" => 3, "entry_id" => "c"},
          %{"position" => 1, "entry_id" => "a"},
          %{"position" => 2, "entry_id" => "b"}
        ])

      fp = Fingerprint.build(draw, sample_operator(), sample_receipt())

      assert fp["winners"] == [
               %{"position" => 1, "entry_id" => "a"},
               %{"position" => 2, "entry_id" => "b"},
               %{"position" => 3, "entry_id" => "c"}
             ]
    end

    test "fingerprint compare ignores incoming winners order" do
      base = sample_draw()

      draw_asc =
        Map.put(base, :results, [
          %{"position" => 1, "entry_id" => "a"},
          %{"position" => 2, "entry_id" => "b"}
        ])

      draw_desc =
        Map.put(base, :results, [
          %{"position" => 2, "entry_id" => "b"},
          %{"position" => 1, "entry_id" => "a"}
        ])

      fp_asc = Fingerprint.build(draw_asc, sample_operator(), sample_receipt(), fixed_now())
      fp_desc = Fingerprint.build(draw_desc, sample_operator(), sample_receipt(), fixed_now())

      assert :ok = Fingerprint.compare(fp_asc, fp_desc)
    end
  end

  describe "compare/2" do
    test "returns :ok when fingerprints are identical" do
      fp = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt())
      assert :ok = Fingerprint.compare(fp, fp)
    end

    test "ignores template_revision and generated_at differences" do
      fp1 = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt(), fixed_now())

      fp2 =
        Map.merge(fp1, %{
          "template_revision" => "999",
          "generated_at" => "2099-12-31T23:59:59.000000Z"
        })

      assert :ok = Fingerprint.compare(fp1, fp2)
    end

    test "returns mismatch list when entry_hash drifts" do
      fp1 = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt())
      fp2 = Map.put(fp1, "entry_hash", "different-hash")

      assert {:error, {:fingerprint_mismatch, ["entry_hash"]}} =
               Fingerprint.compare(fp1, fp2)
    end

    test "returns mismatch list with multiple drifting fields" do
      fp1 = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt())
      fp2 = fp1 |> Map.put("seed", "x") |> Map.put("drand_round", 99_999)

      assert {:error, {:fingerprint_mismatch, fields}} = Fingerprint.compare(fp1, fp2)
      assert Enum.sort(fields) == ["drand_round", "seed"]
    end

    test "detects winners reordering" do
      fp1 = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt())
      fp2 = Map.put(fp1, "winners", Enum.reverse(fp1["winners"]))

      assert {:error, {:fingerprint_mismatch, ["winners"]}} = Fingerprint.compare(fp1, fp2)
    end

    test "detects receipt drift" do
      fp1 = Fingerprint.build(sample_draw(), sample_operator(), sample_receipt())
      fp2 = put_in(fp1, ["receipt", "signing_key_id"], "different-key")

      assert {:error, {:fingerprint_mismatch, ["receipt"]}} = Fingerprint.compare(fp1, fp2)
    end
  end

  # Fixtures ------------------------------------------------------------

  defp sample_draw do
    %{
      id: "00000000-0000-0000-0000-000000000001",
      operator_sequence: 42,
      entry_hash: "entry-hash-hex",
      seed: "seed-hex",
      drand_chain: "chain-hash",
      drand_round: 12_345,
      drand_randomness: "randomness-hex",
      weather_observation_time: ~U[2026-04-08 11:00:00.000000Z],
      weather_value: "12.3",
      results: [
        %{"position" => 1, "entry_id" => "ticket-47"},
        %{"position" => 2, "entry_id" => "ticket-12"}
      ]
    }
  end

  defp sample_operator do
    %{
      id: "00000000-0000-0000-0000-000000000002",
      slug: %Ash.CiString{string: "acme-prizes"}
    }
  end

  defp sample_receipt do
    %{
      sequence: 7,
      signing_key_id: "abcd1234",
      locked_at: ~U[2026-04-01 10:00:00.000000Z],
      payload_jcs: "payload-jcs-bytes",
      signature: "signature-bytes"
    }
  end

  defp fixed_now, do: ~U[2026-04-08 12:00:00.000000Z]
end
