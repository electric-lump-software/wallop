defmodule WallopCore.Resources.ObservationReadiness do
  @moduledoc """
  Whether the service that fetches Land Observations readings can do so:
  one row, written only by a node that runs the `weather` queue, at boot
  and every 10 minutes, as `ready` (that node's
  `WallopCore.Entropy.LandObsClient.key_configured?/0`) and `checked_at`
  (the database clock when it was written). It never holds the key, or
  anything derived from it.

  Observation-weather locks read it, in whichever service runs the lock;
  see `WallopCore.Weather.ObservationReadiness`. It is not a switch: no
  actor can write it, and it is in no receipt or proof.

  Internal only: every action is forbidden to actors.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("observation_readiness")
    repo(WallopCore.Repo)

    check_constraints do
      check_constraint(:singleton, "observation_readiness_single_row",
        check: "singleton = true",
        message: "there is only one readiness row"
      )
    end
  end

  actions do
    defaults([:read])

    # One statement: INSERT ... ON CONFLICT (singleton) DO UPDATE, with
    # checked_at taken from the database clock in that statement.
    create :record do
      transaction?(false)
      accept([:ready])
      upsert?(true)
      upsert_fields([:ready])

      change(atomic_set(:checked_at, expr(fragment("statement_timestamp() AT TIME ZONE 'UTC'"))))

      change(
        atomic_update(:checked_at, expr(fragment("statement_timestamp() AT TIME ZONE 'UTC'")))
      )
    end
  end

  policies do
    policy action_type([:create, :read, :update, :destroy]) do
      forbid_if(always())
    end
  end

  attributes do
    attribute(:singleton, :boolean,
      primary_key?: true,
      allow_nil?: false,
      default: true,
      public?: true
    )

    attribute(:ready, :boolean, allow_nil?: false, public?: true)
    attribute(:checked_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end
end
