defmodule WallopCore.ProofBundle do
  @moduledoc """
  Builds the canonical proof bundle JSON for a completed draw.

  The bundle is the single machine-readable verification artifact for a
  draw — used by the wallop-verify CLI and any third-party verifier.
  `assemble/1` is the only producer of bundle bytes: `build/1` (the live
  `GET /proof/:id.json`) and the vector generators that write
  `spec/vectors/proof-bundle*.json` both call it, so they cannot drift.

  Output is JCS-canonical JSON (RFC 8785) so the bytes are deterministic
  regardless of map ordering.
  """

  alias WallopCore.OperatorInfo
  alias WallopCore.Protocol

  @bundle_version 1

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
        {:ok,
         assemble(%{
           draw_id: draw.id,
           entries: entries_for(draw),
           results: results_for(draw),
           entropy: entropy_for(draw),
           lock_receipt: {lock_receipt.payload_jcs, lock_receipt.signature},
           execution_receipt: {execution_receipt.payload_jcs, execution_receipt.signature},
           inline_keys: %{
             lock: if(lock_schema in @inline_lock_key_schemas, do: operator_pk_hex),
             exec: if(exec_schema in @inline_exec_key_schemas, do: infra_pk_hex)
           }
         })}
    end
  end

  @doc """
  The bundle bytes (JCS) from its parts. Pure: no database, no clock.
  `build/1` calls it for a stored draw; the vector generators call it with
  fixed inputs, so both produce bundles the same way.

    * `entries`: `[%{"uuid" => uuid, "weight" => weight}]`, sorted by uuid;
    * `results`: `[%{"entry_id" => id, "position" => n}]`, in position order;
    * `entropy`: the unsigned entropy block, exactly as it is to appear;
    * `lock_receipt`, `execution_receipt`: `{payload_jcs, raw_signature}`;
    * `inline_keys`: the hex key to put in each receipt's wrapper
      (`operator_public_key_hex`, `infrastructure_public_key_hex`), or nil
      for none.
  """
  @spec assemble(%{
          draw_id: String.t(),
          entries: [map()],
          results: [map()],
          entropy: map(),
          lock_receipt: {binary(), binary()},
          execution_receipt: {binary(), binary()},
          inline_keys: %{lock: String.t() | nil, exec: String.t() | nil}
        }) :: binary()
  def assemble(%{
        draw_id: draw_id,
        entries: entries,
        results: results,
        entropy: entropy,
        lock_receipt: lock_receipt,
        execution_receipt: execution_receipt,
        inline_keys: %{lock: lock_key, exec: exec_key}
      }) do
    Jcs.encode(%{
      "version" => @bundle_version,
      "draw_id" => draw_id,
      "entries" => entries,
      "results" => results,
      "entropy" => entropy,
      "lock_receipt" => receipt_block(lock_receipt, "operator_public_key_hex", lock_key),
      "execution_receipt" =>
        receipt_block(execution_receipt, "infrastructure_public_key_hex", exec_key)
    })
  end

  defp receipt_block({payload_jcs, signature}, key_field, key_hex) do
    base = %{
      "payload_jcs" => payload_jcs,
      "signature_hex" => Base.encode16(signature, case: :lower)
    }

    if is_nil(key_hex), do: base, else: Map.put(base, key_field, key_hex)
  end

  defp receipt_schema_version(payload_jcs) when is_binary(payload_jcs) do
    case Jason.decode(payload_jcs) do
      {:ok, %{"schema_version" => v}} when is_binary(v) -> v
      _ -> nil
    end
  end

  defp entries_for(draw) do
    draw.id
    |> WallopCore.Entries.load_for_draw()
    |> Enum.sort_by(& &1.uuid)
    |> Enum.map(fn e -> %{"uuid" => e.uuid, "weight" => e.weight} end)
  end

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

    freq_tag? = draw.entropy_composition == Protocol.freq_entropy_composition()

    cond do
      freq_tag? and draw.freq_value -> Map.put(base, "freq_value", draw.freq_value)
      freq_tag? -> base
      draw.weather_value -> Map.put(base, "weather_value", draw.weather_value)
      draw.freq_value -> Map.put(base, "freq_value", draw.freq_value)
      true -> base
    end
  end
end
