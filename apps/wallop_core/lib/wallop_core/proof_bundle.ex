defmodule WallopCore.ProofBundle do
  @moduledoc """
  Builds the canonical proof bundle JSON for a completed draw.

  The bundle is the single machine-readable verification artifact for a
  draw — used by the wallop-verify CLI and any third-party verifier.
  This module is the *only* producer of bundle bytes; both the frozen
  test vector at `spec/vectors/proof-bundle.json` and the live HTTP
  endpoint `GET /proof/:id.json` call this function. They cannot drift
  because they share this producer.

  Output is JCS-canonical JSON (RFC 8785) so the bytes are deterministic
  regardless of map ordering.
  """

  alias WallopCore.OperatorInfo

  @bundle_version 1

  @doc """
  Build the proof bundle for a completed draw.

  Returns `{:ok, json_binary}` for completed draws with both receipts,
  or `{:error, reason}` otherwise.
  """
  @spec build(map()) :: {:ok, binary()} | {:error, atom()}
  def build(%{status: :completed} = draw) do
    {_operator, lock_receipt, execution_receipt} = OperatorInfo.for_draw(draw)

    cond do
      is_nil(lock_receipt) -> {:error, :missing_lock_receipt}
      is_nil(execution_receipt) -> {:error, :missing_execution_receipt}
      true -> do_build(draw, lock_receipt, execution_receipt)
    end
  end

  def build(_draw), do: {:error, :draw_not_completed}

  defp do_build(draw, lock_receipt, execution_receipt) do
    {operator_pk_hex, infra_pk_hex} =
      OperatorInfo.signing_keys_hex(lock_receipt, execution_receipt)

    cond do
      is_nil(operator_pk_hex) ->
        {:error, :missing_operator_key}

      is_nil(infra_pk_hex) ->
        {:error, :missing_infrastructure_key}

      true ->
        bundle = %{
          "version" => @bundle_version,
          "draw_id" => draw.id,
          "entries" => entries_for(draw),
          "results" => results_for(draw),
          "entropy" => entropy_for(draw),
          "lock_receipt" => %{
            "payload_jcs" => lock_receipt.payload_jcs,
            "signature_hex" => Base.encode16(lock_receipt.signature, case: :lower),
            "operator_public_key_hex" => operator_pk_hex
          },
          "execution_receipt" => %{
            "payload_jcs" => execution_receipt.payload_jcs,
            "signature_hex" => Base.encode16(execution_receipt.signature, case: :lower),
            "infrastructure_public_key_hex" => infra_pk_hex
          }
        }

        {:ok, Jcs.encode(bundle)}
    end
  end

  defp entries_for(draw) do
    draw.id
    |> WallopCore.Entries.load_for_draw()
    |> Enum.map(fn e -> %{"id" => e.id, "weight" => e.weight} end)
  end

  defp results_for(draw) do
    Enum.map(draw.results || [], fn r ->
      %{"entry_id" => r["entry_id"], "position" => r["position"]}
    end)
  end

  defp entropy_for(draw) do
    base = %{
      "drand_round" => draw.drand_round,
      "drand_randomness" => draw.drand_randomness,
      "drand_signature" => draw.drand_signature,
      "drand_chain_hash" => draw.drand_chain
    }

    if draw.weather_value do
      Map.put(base, "weather_value", draw.weather_value)
    else
      base
    end
  end
end
