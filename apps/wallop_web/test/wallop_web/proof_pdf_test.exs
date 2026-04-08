defmodule WallopWeb.ProofPdfTest do
  @moduledoc """
  Tests for the ProofPdf module's regeneration invariant and storage
  metadata round-trip. The actual PDF rendering path (Gotenberg + qpdf)
  is integration-tested separately and skipped here so this suite
  doesn't need either binary running locally.
  """
  use ExUnit.Case, async: false

  alias WallopWeb.ProofPdf.Fingerprint
  alias WallopWeb.ProofStorage

  setup do
    root = Path.join(System.tmp_dir!(), "proof_pdf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original = Application.get_env(:wallop_web, :proof_storage)

    Application.put_env(:wallop_web, :proof_storage,
      backend: WallopWeb.ProofStorage.Filesystem,
      filesystem: [root: root]
    )

    on_exit(fn ->
      File.rm_rf!(root)
      Application.put_env(:wallop_web, :proof_storage, original)
    end)

    :ok
  end

  describe "metadata storage round-trip" do
    test "put_metadata then get_metadata" do
      :ok = ProofStorage.put_metadata("draw-1", "{\"hello\": \"world\"}")
      assert {:ok, "{\"hello\": \"world\"}"} = ProofStorage.get_metadata("draw-1")
    end

    test "get_metadata returns :not_found for unknown id" do
      assert {:error, :not_found} = ProofStorage.get_metadata("missing")
    end

    test "put_metadata overwrites existing" do
      :ok = ProofStorage.put_metadata("draw-2", "v1")
      :ok = ProofStorage.put_metadata("draw-2", "v2")
      assert {:ok, "v2"} = ProofStorage.get_metadata("draw-2")
    end

    test "metadata and PDF bytes are stored independently" do
      :ok = ProofStorage.put("draw-3", "PDF BYTES")
      :ok = ProofStorage.put_metadata("draw-3", "{\"x\": 1}")
      assert {:ok, "PDF BYTES"} = ProofStorage.get("draw-3")
      assert {:ok, "{\"x\": 1}"} = ProofStorage.get_metadata("draw-3")
    end
  end

  describe "Fingerprint.compare/2 regeneration invariant" do
    # The actual regen check is invoked from inside ProofPdf.generate_and_store/1
    # which also calls qpdf and Gotenberg. We unit-test the invariant
    # behaviour here via Fingerprint.compare directly — the integration
    # test for the full pipeline lives in the integration suite.

    test "same fingerprint passes" do
      fp = sample_fingerprint()
      assert :ok = Fingerprint.compare(fp, fp)
    end

    test "regen with bumped template_revision passes" do
      fp1 = sample_fingerprint()
      fp2 = Map.put(fp1, "template_revision", "2")
      assert :ok = Fingerprint.compare(fp1, fp2)
    end

    test "regen with new generated_at passes" do
      fp1 = sample_fingerprint()
      fp2 = Map.put(fp1, "generated_at", "2099-01-01T00:00:00.000000Z")
      assert :ok = Fingerprint.compare(fp1, fp2)
    end

    test "regen with drifting entry_hash refuses" do
      fp1 = sample_fingerprint()
      fp2 = Map.put(fp1, "entry_hash", "tampered-hash")

      assert {:error, {:fingerprint_mismatch, ["entry_hash"]}} =
               Fingerprint.compare(fp1, fp2)
    end

    test "regen with drifting winners refuses" do
      fp1 = sample_fingerprint()
      fp2 = Map.put(fp1, "winners", [%{"position" => 1, "entry_id" => "different"}])

      assert {:error, {:fingerprint_mismatch, ["winners"]}} =
               Fingerprint.compare(fp1, fp2)
    end

    test "regen with multiple drifts lists all of them" do
      fp1 = sample_fingerprint()

      fp2 =
        fp1
        |> Map.put("entry_hash", "x")
        |> Map.put("seed", "y")
        |> Map.put("drand_round", 999)

      assert {:error, {:fingerprint_mismatch, fields}} = Fingerprint.compare(fp1, fp2)
      assert Enum.sort(fields) == ["drand_round", "entry_hash", "seed"]
    end
  end

  defp sample_fingerprint do
    %{
      "schema_version" => "1",
      "draw_id" => "00000000-0000-0000-0000-000000000001",
      "operator_slug" => "acme",
      "operator_id" => "00000000-0000-0000-0000-000000000002",
      "operator_sequence" => 1,
      "entry_hash" => "hash",
      "seed" => "seed",
      "drand_chain" => "chain",
      "drand_round" => 100,
      "drand_randomness" => "rand",
      "weather_observation_time" => "2026-04-08T11:00:00.000000Z",
      "weather_value" => "10",
      "winners" => [%{"position" => 1, "entry_id" => "x"}],
      "receipt" => nil,
      "template_revision" => "1",
      "generated_at" => "2026-04-08T12:00:00.000000Z"
    }
  end
end
