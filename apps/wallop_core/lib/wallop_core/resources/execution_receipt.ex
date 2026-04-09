defmodule WallopCore.Resources.ExecutionReceipt do
  @moduledoc """
  A signed attestation of a draw's execution output.

  Created in the same transaction as draw completion for any draw whose
  api_key belongs to an operator. Signed by the **wallop infrastructure
  key** (not the operator's key — the operator signed the commitment at
  lock time via `OperatorReceipt`; wallop attests the execution).

  The signed payload (`payload_jcs`) commits to the entropy values, seed,
  results, algorithm versions, and a `lock_receipt_hash` linking it
  cryptographically to the lock-time receipt. Together, the lock receipt
  and execution receipt let a verifier confirm both halves of the
  commit-reveal protocol using only signed bytes and public external
  data (drand, Met Office).

  Append-only: once committed, never updated, never deleted — enforced
  by a Postgres trigger.
  """

  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("execution_receipts")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :draw_id,
        :operator_id,
        :sequence,
        :lock_receipt_hash,
        :payload_jcs,
        :signature,
        :signing_key_id
      ])
    end
  end

  policies do
    policy action(:read) do
      authorize_if(always())
    end

    policy action(:create) do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:draw_id, :uuid, allow_nil?: false, public?: true)
    attribute(:operator_id, :uuid, allow_nil?: false, public?: true)
    attribute(:sequence, :integer, allow_nil?: false, public?: true)
    attribute(:lock_receipt_hash, :string, allow_nil?: false, public?: true)
    attribute(:payload_jcs, :binary, allow_nil?: false, public?: true)
    attribute(:signature, :binary, allow_nil?: false, public?: true)
    attribute(:signing_key_id, :string, allow_nil?: false, public?: true)

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_draw, [:draw_id])
  end

  relationships do
    belongs_to :draw, WallopCore.Resources.Draw do
      allow_nil?(false)
      public?(false)
      attribute_writable?(true)
      define_attribute?(false)
      source_attribute(:draw_id)
    end
  end
end
