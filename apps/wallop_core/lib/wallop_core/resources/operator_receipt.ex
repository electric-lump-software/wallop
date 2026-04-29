defmodule WallopCore.Resources.OperatorReceipt do
  @moduledoc """
  An immutable signed commitment receipt for a locked draw.

  Created in the same transaction as `Draw.lock` for any draw whose api_key
  belongs to an operator. Once committed, never updated, never deleted —
  enforced by a Postgres trigger on `operator_receipts`.

  The signed payload (`payload_jcs`) is JCS-canonical JSON containing
  operator slug+id, sequence, draw_id, commitment_hash, entry_hash, locked_at,
  signing_key_id, schema_version. Signature is raw Ed25519 (64 bytes).
  """

  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("operator_receipts")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :operator_id,
        :draw_id,
        :sequence,
        :commitment_hash,
        :entry_hash,
        :locked_at,
        :signing_key_id,
        :payload_jcs,
        :signature
      ])
    end
  end

  policies do
    # Receipts are the public verification artefact — anyone can read them.
    policy action(:read) do
      authorize_if(always())
    end

    # Creation must go through SignAndStoreReceipt with `authorize?: false`.
    # Without this policy, any caller could forge receipts or DoS in-flight
    # draws by preempting the unique-draw insert.
    policy action(:create) do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:operator_id, :uuid, allow_nil?: false, public?: true)
    attribute(:draw_id, :uuid, allow_nil?: false, public?: true)
    attribute(:sequence, :integer, allow_nil?: false, public?: true)
    attribute(:commitment_hash, :string, allow_nil?: false, public?: true)
    attribute(:entry_hash, :string, allow_nil?: false, public?: true)
    attribute(:locked_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:signing_key_id, :string, allow_nil?: false, public?: true)
    attribute(:payload_jcs, :binary, allow_nil?: false, public?: true)
    attribute(:signature, :binary, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_sequence, [:operator_id, :sequence])
    identity(:unique_draw, [:draw_id])
  end

  relationships do
    belongs_to :operator, WallopCore.Resources.Operator do
      allow_nil?(false)
      public?(false)
      attribute_writable?(true)
    end

    belongs_to :draw, WallopCore.Resources.Draw do
      allow_nil?(false)
      public?(false)
      attribute_writable?(true)
    end
  end
end
