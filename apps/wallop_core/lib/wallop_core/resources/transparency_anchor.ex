defmodule WallopCore.Resources.TransparencyAnchor do
  @moduledoc """
  Periodic Merkle root over all operator receipts, anchored to an external
  append-only log (initially: a drand round number).

  Closes the "wallop forges parallel history" gap. A verifier mirroring the
  receipt log over time can compare the anchor's Merkle root against their
  own computation; tampering with any receipt covered by an anchor is
  detectable. The drand round number provides timestamp evidence that
  predates any retroactive forgery attempt.

  Append-only: enforced by a Postgres trigger.
  """

  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("transparency_anchors")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :merkle_root,
        :receipt_count,
        :from_receipt_id,
        :to_receipt_id,
        :external_anchor_kind,
        :external_anchor_evidence,
        :anchored_at
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:merkle_root, :binary, allow_nil?: false, public?: true)
    attribute(:receipt_count, :integer, allow_nil?: false, public?: true)
    attribute(:from_receipt_id, :uuid, allow_nil?: true, public?: true)
    attribute(:to_receipt_id, :uuid, allow_nil?: false, public?: true)
    attribute(:external_anchor_kind, :string, allow_nil?: true, public?: true)
    attribute(:external_anchor_evidence, :string, allow_nil?: true, public?: true)
    attribute(:anchored_at, :utc_datetime_usec, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
  end
end
