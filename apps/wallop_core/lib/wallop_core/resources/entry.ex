defmodule WallopCore.Resources.Entry do
  @moduledoc "An entry in a draw. Belongs to a Draw."
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("entries")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:draw_id, :entry_id, :weight])
    end

    destroy :destroy do
      primary?(true)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :draw_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :entry_id, :string do
      description(
        "Opaque identifier for this entry, provided by the API consumer. " <>
          "Must be unique within the draw.\n\n" <>
          "**Do not use PII as entry IDs.** The entry list is hashed into a " <>
          "permanent, public proof record that cannot be deleted. Use opaque " <>
          "identifiers (e.g. a UUID from your own system) and keep the mapping " <>
          "from ID to person in your own database."
      )

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

  identities do
    identity(:unique_entry_per_draw, [:draw_id, :entry_id])
  end
end
