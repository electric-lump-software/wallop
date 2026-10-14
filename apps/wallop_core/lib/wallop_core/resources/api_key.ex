defmodule WallopCore.Resources.ApiKey do
  @moduledoc """
  API key for authenticating requests to the Wallop API.

  Keys are generated with a random secret, but only a bcrypt hash, a labelled
  SHA-256 digest (ADR-0014) and an 8-character prefix are persisted. The raw
  key is returned once via metadata after creation and never stored.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("api_keys")
    repo(WallopCore.Repo)

    check_constraints do
      check_constraint(:key_digest, "api_keys_key_digest_length",
        check: "key_digest IS NULL OR octet_length(key_digest) = 32",
        message: "must be 32 bytes"
      )
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:name, :tier, :monthly_draw_limit, :count_reset_at, :operator_id])
      change({WallopCore.Resources.ApiKey.Changes.GenerateKey, []})
    end

    update :set_operator do
      accept([:operator_id])
    end

    # Lazy migration from bcrypt (ADR-0014): records the digest of a key
    # that predates it. Matches only rows with no digest, so a concurrent
    # second writer gets StaleRecord, which callers treat as success.
    # Uses the filter change: a bare `filter(...)` is a no-op on an update action.
    update :record_key_digest do
      accept([:key_digest])
      change(filter(expr(is_nil(key_digest))))
    end

    update :deactivate do
      accept([])

      change(set_attribute(:active, false))
      change(set_attribute(:deactivated_at, &DateTime.utc_now/0))
    end

    # Updates tier metadata. Called by a consumer application on subscription changes.
    update :update_tier do
      accept([:tier, :monthly_draw_limit, :count_reset_at])
    end

    # Increments monthly_draw_count. Called when a draw is created.
    update :increment_draw_count do
      require_atomic?(false)
      change({WallopCore.Resources.ApiKey.Changes.IncrementDrawCount, []})
    end

    update :regenerate_webhook_secret do
      accept([])
      require_atomic?(false)
      change({WallopCore.Resources.ApiKey.Changes.RegenerateWebhookSecret, []})
    end

    # Resets monthly_draw_count to zero and bumps count_reset_at.
    update :reset_draw_count do
      require_atomic?(false)
      change(set_attribute(:monthly_draw_count, 0))
      change({WallopCore.Resources.ApiKey.Changes.AdvanceResetAt, []})
    end
  end

  policies do
    # An actor (an authenticated api key) can read its own row. Anything that
    # needs to read a different api key (lookups by prefix during auth, admin
    # views) must use `authorize?: false`.
    policy action(:read) do
      forbid_unless(actor_present())
      authorize_if(expr(id == ^actor(:id)))
    end

    # All admin/management actions are forbidden via Ash policies. Legitimate
    # callers (mix wallop.gen.api_key, consumer-app admin endpoints, internal
    # change modules) MUST pass `authorize?: false`. Without this policy any
    # caller could mint an api key for any operator and impersonate them under
    # the operator's REAL signing key.
    policy action([
             :create,
             :set_operator,
             :record_key_digest,
             :deactivate,
             :update_tier,
             :increment_draw_count,
             :reset_draw_count,
             :regenerate_webhook_secret
           ]) do
      forbid_if(always())
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

    attribute :key_digest, :binary do
      description(
        "SHA-256 of a label and the raw key (ADR-0014). Nil until first use for keys created before 0.29.0."
      )

      allow_nil?(true)
      sensitive?(true)
      public?(false)
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
      description(
        "Subscription tier name (e.g. 'free', 'starter', 'pro'). Set by the consumer application."
      )

      allow_nil?(true)
      public?(false)
    end

    attribute :monthly_draw_limit, :integer do
      description(
        "Maximum draws per month. Null means unlimited. Set by the consumer application."
      )

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

  relationships do
    belongs_to :operator, WallopCore.Resources.Operator do
      allow_nil?(true)
      public?(false)
      attribute_writable?(true)
    end
  end
end
