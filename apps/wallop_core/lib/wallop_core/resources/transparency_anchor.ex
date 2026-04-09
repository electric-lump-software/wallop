defmodule WallopCore.Resources.TransparencyAnchor do
  @moduledoc """
  Periodic Merkle root over operator receipts and execution receipts,
  anchored to an external append-only log (initially: a drand round number)
  and signed by the wallop infrastructure key.

  The combined root covers two separate sub-trees:

      anchor_root = SHA256("wallop-anchor-v1" || operator_receipts_root || execution_receipts_root)

  The `"wallop-anchor-v1"` prefix provides domain separation from both
  leaf hashes (`0x00`) and internal Merkle nodes (`0x01`), avoiding any
  structural ambiguity with RFC 6962 tree nodes. A verifier who only
  cares about one receipt type can verify their sub-tree independently.

  The `infrastructure_signature` signs the combined root with the infra
  Ed25519 key, making the transparency log itself infra-key-signed.

  Append-only: enforced by a Postgres trigger.
  """

  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

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
        :anchored_at,
        :operator_receipts_root,
        :execution_receipts_root,
        :execution_receipt_count,
        :infrastructure_signature,
        :signing_key_id
      ])
    end
  end

  policies do
    # The transparency log is the public attestation — anyone can read.
    policy action(:read) do
      authorize_if(always())
    end

    # AnchorWorker (cron) creates anchors via `authorize?: false`.
    # Without this policy, any unauthenticated caller could pollute the
    # transparency log with garbage anchors and undermine its trust story.
    policy action(:create) do
      forbid_if(always())
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

    attribute :operator_receipts_root, :binary do
      allow_nil?(true)
      public?(true)
      description("Merkle root over operator receipts only (sub-tree).")
    end

    attribute :execution_receipts_root, :binary do
      allow_nil?(true)
      public?(true)
      description("Merkle root over execution receipts only (sub-tree).")
    end

    attribute :execution_receipt_count, :integer do
      allow_nil?(true)
      public?(true)
      default(0)
    end

    attribute :infrastructure_signature, :binary do
      allow_nil?(true)
      public?(true)
      description("Ed25519 signature over merkle_root by the infra key.")
    end

    attribute :signing_key_id, :string do
      allow_nil?(true)
      public?(true)
      description("Infrastructure key that produced the signature.")
    end

    create_timestamp(:inserted_at)
  end
end
