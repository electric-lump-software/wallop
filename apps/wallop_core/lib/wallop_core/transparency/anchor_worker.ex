defmodule WallopCore.Transparency.AnchorWorker do
  @moduledoc """
  Oban cron worker that builds a Merkle root over all operator receipts
  inserted since the previous anchor and pins it to a drand round.

  Closes the "wallop-held keys can be retroactively forged" gap: a verifier
  who mirrors `/operator/:slug/receipts.json` over time can recompute the
  Merkle root and compare it against the published anchor. The drand round
  number provides external timestamp evidence that predates any forgery
  attempt.

  Idempotent: a run with no new receipts inserts no anchor.
  """
  use Oban.Worker, queue: :default

  require Ash.Query
  require Logger

  alias WallopCore.Entropy.DrandClient
  alias WallopCore.Protocol
  alias WallopCore.Resources.{OperatorReceipt, TransparencyAnchor}

  @impl true
  def perform(_job) do
    case load_unanchored_receipts() do
      [] ->
        Logger.info("AnchorWorker: no new receipts, skipping")
        :ok

      receipts ->
        anchor(receipts)
    end
  end

  defp load_unanchored_receipts do
    last_to_id = last_anchored_receipt_id()

    query =
      OperatorReceipt
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)

    query =
      case last_to_id do
        nil ->
          query

        id ->
          %{rows: [[ts]]} =
            WallopCore.Repo.query!(
              "SELECT inserted_at FROM operator_receipts WHERE id = $1",
              [Ecto.UUID.dump!(id)]
            )

          Ash.Query.filter(query, inserted_at > ^ts)
      end

    Ash.read!(query, authorize?: false)
  end

  defp last_anchored_receipt_id do
    case TransparencyAnchor
         |> Ash.Query.sort(anchored_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read!(authorize?: false) do
      [%{to_receipt_id: id}] -> id
      [] -> nil
    end
  end

  defp anchor(receipts) do
    leaves = Enum.map(receipts, fn r -> r.payload_jcs <> r.signature end)
    root = Protocol.merkle_root(leaves)
    now = DateTime.utc_now()

    {kind, evidence} =
      case fetch_drand_round() do
        {:ok, round} -> {"drand_quicknet", Integer.to_string(round)}
        :error -> {nil, nil}
      end

    first = List.first(receipts)
    last = List.last(receipts)

    {:ok, anchor} =
      TransparencyAnchor
      |> Ash.Changeset.for_create(:create, %{
        merkle_root: root,
        receipt_count: length(receipts),
        from_receipt_id: first.id,
        to_receipt_id: last.id,
        external_anchor_kind: kind,
        external_anchor_evidence: evidence,
        anchored_at: now
      })
      |> Ash.create(authorize?: false)

    Logger.info(
      "AnchorWorker: anchored #{length(receipts)} receipts, root=#{Base.encode16(root, case: :lower)}, drand=#{evidence}"
    )

    {:ok, anchor}
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
