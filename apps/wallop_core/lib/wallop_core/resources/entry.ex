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
      accept([:draw_id, :entry_id, :weight])
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
    # `authorize?: false`. PAM-690: without this, an attacker could insert
    # entries that bypass PII rejection and weight caps. The entries
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

    attribute :entry_id, :string do
      description(
        "Opaque identifier for this entry, provided by the API consumer. " <>
          "Must be unique within the draw. " <>
          "Only alphanumeric characters, hyphens, underscores, dots, colons, and equals signs are allowed " <>
          "(regex: `^[a-zA-Z0-9_\\-:.=]+$`).\n\n" <>
          "**Do not use PII as entry IDs.** Entry IDs are hashed into a " <>
          "permanent, public proof record that cannot be deleted. Email addresses, " <>
          "phone numbers, and names will be rejected. Use opaque identifiers " <>
          "(e.g. a UUID or numeric ID from your own system) and keep the " <>
          "ID-to-person mapping in your own database, where it can be deleted " <>
          "on a GDPR removal request without affecting the proof record."
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
