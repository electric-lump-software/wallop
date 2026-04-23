defmodule WallopCore.Resources.Entry do
  @moduledoc "An entry in a draw. Belongs to a Draw."
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("entries")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:draw_id, :weight])
    end

    destroy :destroy do
      primary?(true)
    end
  end

  policies do
    # Entries are scoped to the api_key that owns the parent draw. Internal
    # readers (executor, fingerprint computation) use `authorize?: false`.
    policy action(:read) do
      forbid_unless(actor_present())
      authorize_if(expr(draw.api_key_id == ^actor(:id)))
    end

    # Direct create/destroy is forbidden — must go through Draw.add_entries
    # and Draw.remove_entry, which run validation and call this with
    # `authorize?: false`. Without this, an attacker could insert entries
    # that bypass the action-level validation and weight caps. The entries
    # immutability trigger (see migration 20260330214428) backstops the
    # post-lock case at the Postgres level.
    policy action([:create, :destroy]) do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :draw_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :weight, :integer do
      description(
        "Weighting for this entry. Higher weight increases the probability of " <>
          "being selected. Must be between 1 and 1,000. Default is 1 (equal chance)."
      )

      allow_nil?(false)
      default(1)
      public?(true)
      constraints(min: 1, max: 1_000)
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
end
