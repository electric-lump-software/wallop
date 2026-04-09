defmodule WallopCore.Transparency.AnchorWorker do
  @moduledoc """
  Oban cron worker that builds a Merkle root over all operator receipts
  and execution receipts inserted since the previous anchor, pins it to
  a drand round, and signs the root with the infrastructure key.

  The combined root covers two separate sub-trees:

      anchor_root = SHA256(0x01 || operator_receipts_root || execution_receipts_root)

  The `0x01` prefix provides domain separation from leaf hashes (`0x00`),
  following RFC 6962 conventions. A verifier who only cares about one
  receipt type can verify their sub-tree independently.

  The `infrastructure_signature` signs the combined root with the infra
  Ed25519 key, making the transparency log itself infra-key-signed.

  Idempotent: a run with no new receipts of either type inserts no anchor.
  """
  use Oban.Worker, queue: :default

  require Ash.Query
  require Logger

  alias WallopCore.Entropy.DrandClient
  alias WallopCore.Protocol

  alias WallopCore.Resources.{
    ExecutionReceipt,
    InfrastructureSigningKey,
    OperatorReceipt,
    TransparencyAnchor
  }

  alias WallopCore.Vault

  @impl true
  def perform(_job) do
    op_receipts = load_unanchored_receipts(OperatorReceipt, :operator_receipts)
    exec_receipts = load_unanchored_receipts(ExecutionReceipt, :execution_receipts)

    case {op_receipts, exec_receipts} do
      {[], []} ->
        Logger.info("AnchorWorker: no new receipts, skipping")
        :ok

      _ ->
        anchor(op_receipts, exec_receipts)
    end
  end

  defp load_unanchored_receipts(resource, _kind) do
    cutoff = last_anchor_time()

    query =
      resource
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)

    query =
      case cutoff do
        nil -> query
        ts -> Ash.Query.filter(query, inserted_at > ^ts)
      end

    Ash.read!(query, authorize?: false)
  end

  defp last_anchor_time do
    case TransparencyAnchor
         |> Ash.Query.sort(anchored_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read!(authorize?: false) do
      [%{anchored_at: ts}] -> ts
      [] -> nil
    end
  end

  defp anchor(op_receipts, exec_receipts) do
    # Build separate sub-tree roots
    op_leaves = Enum.map(op_receipts, fn r -> r.payload_jcs <> r.signature end)
    exec_leaves = Enum.map(exec_receipts, fn r -> r.payload_jcs <> r.signature end)

    op_root = Protocol.merkle_root(op_leaves)
    exec_root = Protocol.merkle_root(exec_leaves)

    # Combined root with 0x01 domain separation (RFC 6962 internal node prefix)
    combined_root = :crypto.hash(:sha256, <<1>> <> op_root <> exec_root)

    now = DateTime.utc_now()

    {kind, evidence} =
      case fetch_drand_round() do
        {:ok, round} -> {"drand_quicknet", Integer.to_string(round)}
        :error -> {nil, nil}
      end

    # Sign the combined root with the infrastructure key
    {signature, key_id} = sign_root(combined_root)

    # Use the latest receipt (by inserted_at) from either set for the range
    all_receipts = op_receipts ++ exec_receipts
    sorted = Enum.sort_by(all_receipts, & &1.inserted_at, DateTime)
    first = List.first(sorted)
    last = List.last(sorted)

    {:ok, anchor} =
      TransparencyAnchor
      |> Ash.Changeset.for_create(:create, %{
        merkle_root: combined_root,
        operator_receipts_root: op_root,
        execution_receipts_root: exec_root,
        receipt_count: length(op_receipts),
        execution_receipt_count: length(exec_receipts),
        from_receipt_id: if(first, do: first.id),
        to_receipt_id: last.id,
        external_anchor_kind: kind,
        external_anchor_evidence: evidence,
        infrastructure_signature: signature,
        signing_key_id: key_id,
        anchored_at: now
      })
      |> Ash.create(authorize?: false)

    Logger.info(
      "AnchorWorker: anchored #{length(op_receipts)} operator + #{length(exec_receipts)} execution receipts, " <>
        "root=#{Base.encode16(combined_root, case: :lower)}, drand=#{evidence}, key=#{key_id}"
    )

    {:ok, anchor}
  end

  defp sign_root(root) do
    case load_current_infra_key() do
      {:ok, key} ->
        {:ok, private_key} = Vault.decrypt(key.private_key)
        signature = Protocol.sign_receipt(root, private_key)
        {signature, key.key_id}

      :error ->
        Logger.warning("AnchorWorker: no infrastructure key — anchor will not be signed")
        {nil, nil}
    end
  end

  defp load_current_infra_key do
    now = DateTime.utc_now()

    InfrastructureSigningKey
    |> Ash.Query.filter(valid_from <= ^now)
    |> Ash.Query.sort(valid_from: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [key] -> {:ok, key}
      [] -> :error
    end
  end

  defp fetch_drand_round do
    case DrandClient.current_round(DrandClient.quicknet_chain_hash()) do
      {:ok, round} when is_integer(round) -> {:ok, round}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
