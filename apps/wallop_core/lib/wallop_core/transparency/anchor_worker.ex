defmodule WallopCore.Transparency.AnchorWorker do
  @moduledoc """
  Oban cron worker that builds a Merkle root over all operator receipts
  and execution receipts inserted since the previous anchor, pins it to
  a drand round, and signs the root with the infrastructure key.

  The combined root covers two separate sub-trees:

      anchor_root = SHA256("wallop-anchor-v1" || operator_receipts_root || execution_receipts_root)

  The `"wallop-anchor-v1"` prefix provides domain separation from both
  leaf hashes (`0x00`) and internal Merkle nodes (`0x01`), avoiding any
  structural ambiguity with RFC 6962 tree nodes.

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

  # Domain separation prefix for the combined anchor root.
  # Distinct from <<0>> (leaf) and <<1>> (internal node) to avoid
  # structural ambiguity with the Merkle tree's own node hashes.
  @anchor_root_prefix "wallop-anchor-v1"

  @impl true
  def perform(_job) do
    op_receipts = load_unanchored_receipts(OperatorReceipt)
    exec_receipts = load_unanchored_receipts(ExecutionReceipt)

    case {op_receipts, exec_receipts} do
      {[], []} ->
        Logger.info("AnchorWorker: no new receipts, skipping")
        :ok

      _ ->
        anchor(op_receipts, exec_receipts)
    end
  end

  @doc """
  Compute the combined anchor root from two sub-tree roots.

  Public for verification in tests and by third-party verifiers.
  """
  @spec combined_root(binary(), binary()) :: <<_::256>>
  def combined_root(op_root, exec_root)
      when byte_size(op_root) == 32 and byte_size(exec_root) == 32 do
    :crypto.hash(:sha256, @anchor_root_prefix <> op_root <> exec_root)
  end

  defp load_unanchored_receipts(resource) do
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
    # Build separate sub-tree roots with length-prefixed leaves
    op_root = build_sub_tree(op_receipts)
    exec_root = build_sub_tree(exec_receipts)

    root = combined_root(op_root, exec_root)

    {kind, evidence} =
      case fetch_drand_round() do
        {:ok, round} -> {"drand_quicknet", Integer.to_string(round)}
        :error -> {nil, nil}
      end

    # Sign the combined root with the infrastructure key — fail if missing
    case sign_root(root) do
      {:ok, signature, key_id} ->
        create_anchor(%{
          op_receipts: op_receipts,
          exec_receipts: exec_receipts,
          root: root,
          op_root: op_root,
          exec_root: exec_root,
          kind: kind,
          evidence: evidence,
          signature: signature,
          key_id: key_id
        })

      :error ->
        {:error, "no infrastructure signing key — run mix wallop.bootstrap_infrastructure_key"}
    end
  end

  defp build_sub_tree(receipts) do
    leaves =
      Enum.map(receipts, fn r ->
        # Length-prefix payload_jcs so the boundary with signature is
        # unambiguous regardless of signing algorithm.
        payload_len = byte_size(r.payload_jcs)
        <<payload_len::32>> <> r.payload_jcs <> r.signature
      end)

    Protocol.merkle_root(leaves)
  end

  defp create_anchor(%{
         op_receipts: op_receipts,
         exec_receipts: exec_receipts,
         root: root,
         op_root: op_root,
         exec_root: exec_root,
         kind: kind,
         evidence: evidence,
         signature: signature,
         key_id: key_id
       }) do
    all_receipts = op_receipts ++ exec_receipts
    sorted = Enum.sort_by(all_receipts, & &1.inserted_at, DateTime)
    first = List.first(sorted)
    last = List.last(sorted)

    # Use the latest receipt's inserted_at as anchored_at to close
    # clock-drift gaps between Elixir and Postgres timestamps.
    anchored_at = last.inserted_at

    {:ok, anchor} =
      TransparencyAnchor
      |> Ash.Changeset.for_create(:create, %{
        merkle_root: root,
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
        anchored_at: anchored_at
      })
      |> Ash.create(authorize?: false)

    Logger.info(
      "AnchorWorker: anchored #{length(op_receipts)} operator + #{length(exec_receipts)} execution receipts, " <>
        "root=#{Base.encode16(root, case: :lower)}, drand=#{evidence}, key=#{key_id}"
    )

    {:ok, anchor}
  end

  defp sign_root(root) do
    case load_current_infra_key() do
      {:ok, key} ->
        {:ok, private_key} = Vault.decrypt(key.private_key)
        signature = Protocol.sign_receipt(root, private_key)
        {:ok, signature, key.key_id}

      :error ->
        Logger.error("AnchorWorker: no infrastructure signing key found")
        :error
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
    e ->
      Logger.warning("AnchorWorker: drand fetch failed: #{inspect(e)}")
      :error
  end
end
