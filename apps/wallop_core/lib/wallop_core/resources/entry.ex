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
      accept([:id, :draw_id, :weight])
    end

    destroy :destroy do
      primary?(true)
    end
  end

  policies do
    policy action(:read) do
      forbid_unless(actor_present())
      authorize_if(expr(draw.api_key_id == ^actor(:id)))
    end

    policy action([:create, :destroy]) do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id, writable?: true)

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
