defmodule WallopCore.Resources.AddEntriesIdempotency do
  @moduledoc """
  Idempotency state for `Draw.add_entries`. Operational only — never
  read during receipt construction. See ADR-0012.

  Stores `(draw_id, client_ref_digest)` as the unique idempotency key,
  with a `payload_digest` for byte-stable replay comparison and the
  `entry_ids` of the original successful batch for response replay.

  All actions are `forbid_if(always())` for external callers. Internal
  paths (the `add_entries` and `lock` actions) call with
  `authorize?: false`.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("add_entries_idempotency")
    repo(WallopCore.Repo)

    references do
      reference(:draw, on_delete: :delete)
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:draw_id, :client_ref_digest, :payload_digest, :entry_ids])
    end

    destroy :destroy do
      primary?(true)
    end
  end

  policies do
    policy action_type([:create, :read, :destroy]) do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :draw_id, :uuid do
      allow_nil?(false)
    end

    attribute :client_ref_digest, :binary do
      allow_nil?(false)
    end

    attribute :payload_digest, :binary do
      allow_nil?(false)
    end

    # Ordered array of Entry UUIDs (submission order). For HTTP response
    # replay only — never an input to receipt construction (entry_hash,
    # seed, signing). See ADR-0012 receipt-invariance commitment.
    attribute :entry_ids, {:array, :uuid} do
      allow_nil?(false)
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :draw, WallopCore.Resources.Draw do
      attribute_writable?(true)
      define_attribute?(false)
      source_attribute(:draw_id)
    end
  end

  identities do
    identity(:draw_client_ref, [:draw_id, :client_ref_digest])
  end
end
