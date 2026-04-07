defmodule WallopCore.Resources.ApiKey do
  @moduledoc """
  API key for authenticating requests to the Wallop API.

  Keys are generated with a random secret, but only the bcrypt hash and an
  8-character prefix are persisted. The raw key is returned once via metadata
  after creation and never stored.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("api_keys")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:name, :tier, :monthly_draw_limit, :count_reset_at])
      change({WallopCore.Resources.ApiKey.Changes.GenerateKey, []})
    end

    update :deactivate do
      accept([])

      change(set_attribute(:active, false))
      change(set_attribute(:deactivated_at, &DateTime.utc_now/0))
    end

    # Updates tier metadata. Called by wallop-app on subscription changes.
    update :update_tier do
      accept([:tier, :monthly_draw_limit, :count_reset_at])
    end

    # Increments monthly_draw_count. Called when a draw is created.
    update :increment_draw_count do
      require_atomic?(false)
      change({WallopCore.Resources.ApiKey.Changes.IncrementDrawCount, []})
    end

    # Resets monthly_draw_count to zero and bumps count_reset_at.
    update :reset_draw_count do
      require_atomic?(false)
      change(set_attribute(:monthly_draw_count, 0))
      change({WallopCore.Resources.ApiKey.Changes.AdvanceResetAt, []})
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :key_hash, :string do
      allow_nil?(false)
      sensitive?(true)
      public?(false)
    end

    attribute :key_prefix, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :active, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :webhook_secret, :string do
      allow_nil?(true)
      public?(false)
    end

    attribute :deactivated_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    attribute :tier, :string do
      description("Subscription tier name (e.g. 'free', 'starter', 'pro'). Set by wallop-app.")
      allow_nil?(true)
      public?(false)
    end

    attribute :monthly_draw_limit, :integer do
      description("Maximum draws per month. Null means unlimited. Set by wallop-app.")
      allow_nil?(true)
      public?(false)
    end

    attribute :monthly_draw_count, :integer do
      description("Current month's draw count. Reset by reset_draw_count action.")
      allow_nil?(false)
      default(0)
      public?(false)
    end

    attribute :count_reset_at, :utc_datetime_usec do
      description("When the monthly count was last reset (or should next reset).")
      allow_nil?(true)
      public?(false)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_prefix, [:key_prefix])
  end
end
