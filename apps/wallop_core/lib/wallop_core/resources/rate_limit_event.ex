defmodule WallopCore.Resources.RateLimitEvent do
  @moduledoc """
  A minute in which an API key came close to (`:near_limit`, 80%) or hit
  (`:limited`) its per-minute limit, or was refused by its monthly quota
  (`:quota_limited`). At most one row per key, kind and minute; never one per
  request. Operators alert on sustained pressure from these rows.

  Internal: no policy allows any caller. Readers use `authorize?: false`
  and the `:recent` action. Rows older than the retention period
  (30 days by default) are pruned daily by `WallopCore.RateLimitEvents.PruneWorker`.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("rate_limit_events")
    repo(WallopCore.Repo)

    references do
      reference(:api_key, on_delete: :delete)
    end

    custom_indexes do
      # Alerting reads "the last N minutes across all keys"; pruning deletes
      # by age. The unique index leads with api_key_id and serves neither.
      index([:window_start])
    end
  end

  actions do
    defaults([:read, :destroy])

    # The contract consumer applications read for alerting. Keep its name,
    # argument and attributes stable.
    read :recent do
      description("Events whose minute started at or after `since`, newest first.")
      argument(:since, :utc_datetime, allow_nil?: false)
      filter(expr(window_start >= ^arg(:since)))
      prepare(build(sort: [window_start: :desc]))
    end

    create :record do
      accept([:api_key_id, :kind, :limit_per_minute, :window_start])
      upsert?(true)
      upsert_identity(:one_per_window)
      upsert_fields([:limit_per_minute])
    end
  end

  policies do
    policy always() do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :kind, :atom do
      constraints(one_of: [:near_limit, :limited, :quota_limited])
      allow_nil?(false)
      public?(true)
    end

    attribute :limit_per_minute, :integer do
      description(
        "The key's limit when the event was recorded (draws per month for :quota_limited)."
      )

      allow_nil?(false)
      public?(true)
    end

    attribute :window_start, :utc_datetime do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :api_key, WallopCore.Resources.ApiKey do
      allow_nil?(false)
      public?(true)
    end
  end

  identities do
    identity(:one_per_window, [:api_key_id, :kind, :window_start])
  end
end
