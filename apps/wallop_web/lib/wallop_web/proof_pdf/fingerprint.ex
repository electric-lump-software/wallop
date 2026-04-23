defmodule WallopWeb.ProofPdf.Fingerprint do
  @moduledoc """
  Builds the canonical `proof.json` fingerprint that is embedded inside
  every proof PDF as an attachment.

  The fingerprint is the verification anchor for the PDF. A third party
  with only the PDF bytes can extract it (via `qpdf --show-attachment`
  or any PDF library), parse the JSON, and independently verify the
  draw against the public receipt log without trusting the rendered
  HTML inside the PDF.

  ## Schema

      {
        "schema_version": "1",
        "draw_id":          "<uuid>",
        "operator_slug":    "<slug>",
        "operator_id":      "<uuid>",
        "operator_sequence": <int>,
        "entry_hash":       "<hex>",
        "seed":             "<hex>",
        "drand_chain":      "<hex>",
        "drand_round":      <int>,
        "drand_randomness": "<hex>",
        "weather_observation_time": "<iso8601>",
        "weather_value":    "<string>",
        "winners":          [{"position": 1, "entry_id": "..."}, ...],
        "receipt": {
          "sequence":         <int>,
          "signing_key_id":   "<hex>",
          "locked_at":        "<iso8601>",
          "payload_jcs_b64":  "<base64>",
          "signature_b64":    "<base64>"
        },
        "template_revision": "<string>",
        "generated_at":     "<iso8601>"
      }

  Sorted keys, JCS-canonical (RFC 8785) via `Jcs.encode/1` — same code
  path used by the operator receipt commitment, so verifiers only need
  to know one canonicalisation algorithm.

  ## Regeneration invariant

  Every field except `template_revision` and `generated_at` must be
  byte-identical between any two fingerprints generated for the same
  draw. `WallopWeb.ProofPdf` enforces this when regenerating: it reads
  the previously-stored fingerprint and refuses to overwrite if the
  underlying draw data has somehow changed.
  """

  @schema_version "1"
  # Bump only when the fingerprint shape changes in a way that breaks
  # verifiers. Layout / styling changes do not bump this.
  @template_revision "1"

  @doc """
  Build the fingerprint map for a draw. Pure — no DB, no IO. Caller
  passes the operator and receipt structs alongside the draw.
  """
  @spec build(map(), map() | nil, map() | nil, DateTime.t() | nil) :: map()
  def build(draw, operator, receipt, generated_at \\ nil) do
    %{
      "schema_version" => @schema_version,
      "draw_id" => draw.id,
      "operator_slug" => operator_slug(operator),
      "operator_id" => operator_id(operator),
      "operator_sequence" => draw.operator_sequence,
      "entry_hash" => draw.entry_hash,
      "seed" => draw.seed,
      "drand_chain" => draw.drand_chain,
      "drand_round" => draw.drand_round,
      "drand_randomness" => draw.drand_randomness,
      "weather_observation_time" => iso8601(draw.weather_observation_time),
      "weather_value" => draw.weather_value,
      "winners" => normalise_winners(draw.results),
      "receipt" => receipt_block(receipt),
      "template_revision" => @template_revision,
      "generated_at" => iso8601(generated_at || DateTime.utc_now())
    }
  end

  @doc """
  JCS-canonical encoding of a fingerprint map. Same canonicalisation
  used by the operator receipt — verifiers learn one algorithm, not two.
  """
  @spec encode(map()) :: binary()
  def encode(map) when is_map(map), do: Jcs.encode(map)

  @doc """
  Compare two fingerprints. Returns `:ok` if they are equivalent
  ignoring `template_revision` and `generated_at`, otherwise
  `{:error, {:fingerprint_mismatch, top_level_diff_keys}}`.

  This is the regeneration invariant guardrail: a v2 fingerprint must
  match a v1 fingerprint on every field that depends on the underlying
  draw data. Layout-only changes don't drift this.

  Implementation: encode both stripped maps to JCS-canonical bytes and
  compare the bytes. This sidesteps every Elixir-equality / round-trip
  asymmetry trap (atom-vs-string keys, integer-vs-float, list ordering)
  by reducing the comparison to "do these produce identical canonical
  JSON?". If the bytes differ, do a top-level key diff via JCS so the
  error message points at the drifting field.
  """
  @spec compare(map(), map()) :: :ok | {:error, {:fingerprint_mismatch, [String.t()]}}
  def compare(a, b) when is_map(a) and is_map(b) do
    a_stripped = Map.drop(a, ["template_revision", "generated_at"])
    b_stripped = Map.drop(b, ["template_revision", "generated_at"])

    if Jcs.encode(a_stripped) == Jcs.encode(b_stripped) do
      :ok
    else
      {:error, {:fingerprint_mismatch, top_level_diff_keys(a_stripped, b_stripped)}}
    end
  end

  defp top_level_diff_keys(a, b) do
    keys = Enum.uniq(Map.keys(a) ++ Map.keys(b))

    Enum.filter(keys, fn k ->
      Jcs.encode(%{k => Map.get(a, k)}) != Jcs.encode(%{k => Map.get(b, k)})
    end)
  end

  defp operator_slug(nil), do: nil
  defp operator_slug(%{slug: slug}), do: to_string(slug)

  defp operator_id(nil), do: nil
  defp operator_id(%{id: id}), do: id

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: WallopCore.Time.to_rfc3339_usec(dt)

  defp normalise_winners(nil), do: []

  defp normalise_winners(results) when is_list(results) do
    results
    |> Enum.map(fn r ->
      %{
        "position" => Map.get(r, "position") || Map.get(r, :position),
        "entry_id" => Map.get(r, "entry_id") || Map.get(r, :entry_id)
      }
    end)
    |> Enum.sort_by(& &1["position"])
  end

  defp receipt_block(nil), do: nil

  defp receipt_block(receipt) do
    %{
      "sequence" => receipt.sequence,
      "signing_key_id" => receipt.signing_key_id,
      "locked_at" => iso8601(receipt.locked_at),
      "payload_jcs_b64" => Base.encode64(receipt.payload_jcs),
      "signature_b64" => Base.encode64(receipt.signature)
    }
  end
end
