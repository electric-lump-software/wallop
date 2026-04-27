defmodule WallopWeb.OperatorController do
  @moduledoc """
  Public endpoints for operator transparency artifacts: signed receipts and
  the current Ed25519 public key.

  All endpoints are read-only and cacheable. Receipts are append-only and
  individually immutable; the list endpoint uses an ETag derived from
  `MAX(sequence)` so mirrors can detect new entries cheaply.
  """
  use WallopWeb, :controller

  require Ash.Query

  alias WallopCore.Resources.{ExecutionReceipt, Operator, OperatorReceipt, OperatorSigningKey}

  def receipts_index(conn, %{"slug" => slug}) do
    case load_operator(slug) do
      {:ok, operator} ->
        receipts = list_receipts(operator.id)
        max_seq = receipts |> Enum.map(& &1.sequence) |> Enum.max(fn -> 0 end)
        etag = "W/\"op-#{operator.id}-#{max_seq}\""

        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header("cache-control", "public, max-age=60")
        |> json(%{
          operator: operator_summary(operator),
          count: length(receipts),
          receipts: Enum.map(receipts, &serialise_receipt/1)
        })

      :error ->
        not_found(conn)
    end
  end

  def receipt_show(conn, %{"slug" => slug, "sequence" => seq_str}) do
    with {seq, ""} <- Integer.parse(seq_str),
         {:ok, operator} <- load_operator(slug),
         {:ok, receipt} <- find_receipt(operator.id, seq) do
      conn
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> json(%{
        operator: operator_summary(operator),
        receipt: serialise_receipt(receipt)
      })
    else
      _ -> not_found(conn)
    end
  end

  def key_pub(conn, %{"slug" => slug}) do
    case load_operator(slug) do
      {:ok, operator} ->
        case current_key(operator.id) do
          {:ok, key} ->
            conn
            |> put_resp_content_type("application/octet-stream")
            |> put_resp_header("cache-control", "public, max-age=300")
            |> put_resp_header(
              "x-wallop-key-id",
              key.key_id
            )
            |> send_resp(200, key.public_key)

          :error ->
            not_found(conn)
        end

      :error ->
        not_found(conn)
    end
  end

  def keys_index(conn, %{"slug" => slug}) do
    case load_operator(slug) do
      {:ok, operator} ->
        keys = list_keys(operator.id)

        conn
        |> put_resp_header("cache-control", "public, max-age=300")
        |> json(%{
          operator: operator_summary(operator),
          keys:
            Enum.map(keys, fn k ->
              # `inserted_at` is the keyring entry's first-existence timestamp
              # — load-bearing for the spec §4.2.4 temporal binding rule
              # (verifier MUST reject if `key.inserted_at > receipt.binding_timestamp`).
              # `key_class` discriminates operator vs infrastructure keys per
              # ADR-0009; this endpoint serves only :operator keys (infra keys
              # live at /infrastructure/key) but the field is named explicitly so
              # consumers can apply the per-receipt comparison rule without a
              # second resolution step.
              %{
                key_id: k.key_id,
                public_key_hex: Base.encode16(k.public_key, case: :lower),
                valid_from: k.valid_from,
                inserted_at: k.inserted_at,
                key_class: "operator"
              }
            end)
        })

      :error ->
        not_found(conn)
    end
  end

  def executions_index(conn, %{"slug" => slug}) do
    case load_operator(slug) do
      {:ok, operator} ->
        receipts = list_execution_receipts(operator.id)
        max_seq = receipts |> Enum.map(& &1.sequence) |> Enum.max(fn -> 0 end)
        etag = "W/\"exec-#{operator.id}-#{max_seq}\""

        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header("cache-control", "public, max-age=60")
        |> json(%{
          operator: operator_summary(operator),
          count: length(receipts),
          execution_receipts: Enum.map(receipts, &serialise_execution_receipt/1)
        })

      :error ->
        not_found(conn)
    end
  end

  def execution_show(conn, %{"slug" => slug, "sequence" => seq_str}) do
    with {seq, ""} <- Integer.parse(seq_str),
         {:ok, operator} <- load_operator(slug),
         {:ok, receipt} <- find_execution_receipt(operator.id, seq) do
      conn
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> json(%{
        operator: operator_summary(operator),
        execution_receipt: serialise_execution_receipt(receipt)
      })
    else
      _ -> not_found(conn)
    end
  end

  defp load_operator(slug) do
    Operator
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Operator{} = op} -> {:ok, op}
      _ -> :error
    end
  end

  defp list_receipts(operator_id) do
    OperatorReceipt
    |> Ash.Query.filter(operator_id == ^operator_id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp find_receipt(operator_id, sequence) do
    OperatorReceipt
    |> Ash.Query.filter(operator_id == ^operator_id and sequence == ^sequence)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %OperatorReceipt{} = r} -> {:ok, r}
      _ -> :error
    end
  end

  defp current_key(operator_id) do
    now = DateTime.utc_now()

    OperatorSigningKey
    |> Ash.Query.filter(operator_id == ^operator_id and valid_from <= ^now)
    |> Ash.Query.sort(valid_from: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [key] -> {:ok, key}
      [] -> :error
    end
  end

  defp list_keys(operator_id) do
    OperatorSigningKey
    |> Ash.Query.filter(operator_id == ^operator_id)
    |> Ash.Query.sort(valid_from: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp list_execution_receipts(operator_id) do
    ExecutionReceipt
    |> Ash.Query.filter(operator_id == ^operator_id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp find_execution_receipt(operator_id, sequence) do
    ExecutionReceipt
    |> Ash.Query.filter(operator_id == ^operator_id and sequence == ^sequence)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ExecutionReceipt{} = r} -> {:ok, r}
      _ -> :error
    end
  end

  defp operator_summary(operator) do
    %{id: operator.id, slug: to_string(operator.slug), name: operator.name}
  end

  defp serialise_receipt(r) do
    %{
      sequence: r.sequence,
      draw_id: r.draw_id,
      commitment_hash: r.commitment_hash,
      entry_hash: r.entry_hash,
      locked_at: r.locked_at,
      signing_key_id: r.signing_key_id,
      payload: Jason.decode!(r.payload_jcs),
      payload_jcs_b64: Base.encode64(r.payload_jcs),
      signature_b64: Base.encode64(r.signature)
    }
  end

  defp serialise_execution_receipt(r) do
    %{
      sequence: r.sequence,
      draw_id: r.draw_id,
      lock_receipt_hash: r.lock_receipt_hash,
      signing_key_id: r.signing_key_id,
      payload: Jason.decode!(r.payload_jcs),
      payload_jcs_b64: Base.encode64(r.payload_jcs),
      signature_b64: Base.encode64(r.signature)
    }
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{error: "not found"})
  end
end
