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

  # Lock-receipt schema versions whose bundle wrapper MUST carry an inline
  # `operator_public_key_hex` for self-consistency verification. v5 omits
  # the inline key — verifiers resolve operator keys via `KeyResolver`
  # against `/operator/:slug/keys` or an operator-published pin per
  # spec §4.2.4. The verifier's `BundleShape` step rejects any mismatch
  # (v5 + inline key as downgrade-relabel; legacy + missing key as
  # upgrade-spoof).
  @inline_lock_key_schemas ~w(4)
  @inline_exec_key_schemas ~w(2 3)

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

    lock_schema = receipt_schema_version(lock_receipt.payload_jcs)
    exec_schema = receipt_schema_version(execution_receipt.payload_jcs)

    cond do
      lock_schema in @inline_lock_key_schemas and is_nil(operator_pk_hex) ->
        {:error, :missing_operator_key}

      exec_schema in @inline_exec_key_schemas and is_nil(infra_pk_hex) ->
        {:error, :missing_infrastructure_key}

      true ->
        bundle = %{
          "version" => @bundle_version,
          "draw_id" => draw.id,
          "entries" => entries_for(draw),
          "results" => results_for(draw),
          "entropy" => entropy_for(draw),
          "lock_receipt" =>
            receipt_block(
              lock_receipt,
              if(lock_schema in @inline_lock_key_schemas,
                do: {"operator_public_key_hex", operator_pk_hex},
                else: nil
              )
            ),
          "execution_receipt" =>
            receipt_block(
              execution_receipt,
              if(exec_schema in @inline_exec_key_schemas,
                do: {"infrastructure_public_key_hex", infra_pk_hex},
                else: nil
              )
            )
        }

        {:ok, Jcs.encode(bundle)}
    end
  end

  defp receipt_block(receipt, key_pair) do
    base = %{
      "payload_jcs" => receipt.payload_jcs,
      "signature_hex" => Base.encode16(receipt.signature, case: :lower)
    }

    case key_pair do
      nil -> base
      {key, value} -> Map.put(base, key, value)
    end
  end

  # Pulls schema_version off a JCS-encoded receipt payload without
  # re-implementing the parser. Returns nil if the payload is malformed —
  # callers treat that as "no inline-key requirement" which fails any
  # downstream signature check anyway.
  defp receipt_schema_version(payload_jcs) when is_binary(payload_jcs) do
    case Jason.decode(payload_jcs) do
      {:ok, %{"schema_version" => v}} when is_binary(v) -> v
      _ -> nil
    end
  end

  # Entries are sorted by uuid for deterministic bundle bytes. Entries.load_for_draw/1
  # has no ORDER BY, so two calls for the same draw could return different orders,
  # which would produce different JCS-encoded bundle bytes for the same logical
  # draw. Third-party verifiers caching bundle hashes depend on byte stability.
  defp entries_for(draw) do
    draw.id
    |> WallopCore.Entries.load_for_draw()
    |> Enum.sort_by(& &1.uuid)
    |> Enum.map(fn e -> %{"uuid" => e.uuid, "weight" => e.weight} end)
  end

  # Results are sorted by position defensively. The execution receipt's results
  # are stored in position order, but PostgreSQL JSONB does not strictly guarantee
  # array order preservation across all operations — sorting here is cheap
  # insurance and matches the canonical "winners in position order" contract.
  defp results_for(draw) do
    (draw.results || [])
    |> Enum.sort_by(& &1["position"])
    |> Enum.map(fn r -> %{"entry_id" => r["entry_id"], "position" => r["position"]} end)
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
