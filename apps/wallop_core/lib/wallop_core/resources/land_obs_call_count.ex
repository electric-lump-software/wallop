defmodule WallopCore.Resources.LandObsCallCount do
  @moduledoc """
  How many Land Observations calls have been reserved on each UTC day, one
  row per day. The Met Office's daily allowance resets at 00:00 UTC, and the
  day is read from the database clock, so every node counts against the
  same row.

  A reservation is counted before the call is made, whether or not it is
  then refused at the daily cap, so `calls` can pass the cap. Used only
  through `WallopCore.Weather.LandObsBudget`.

  Internal only: every action is forbidden to actors.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("land_obs_call_counts")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    # One statement, upserting on the primary key, with the day taken from
    # the database clock in the same statement: INSERT ... ON CONFLICT
    # (utc_day) DO UPDATE SET calls = calls + 1 RETURNING calls. No
    # transaction, so it holds no row lock beyond the statement.
    create :reserve do
      transaction?(false)
      accept([])
      upsert?(true)
      upsert_fields([])

      change(
        atomic_set(:utc_day, expr(fragment("(statement_timestamp() AT TIME ZONE 'UTC')::date")))
      )

      change(set_attribute(:calls, 1))
      change(set_attribute(:cap_reported, false))
      change(atomic_update(:calls, expr(calls + 1)))
    end

    # Set once a day, by the first refusal at the cap; the caller filters on
    # cap_reported == false, so exactly one caller sees it change.
    update :mark_cap_reported do
      accept([])
      change(set_attribute(:cap_reported, true))
    end
  end

  policies do
    policy action_type([:create, :read, :update]) do
      forbid_if(always())
    end
  end

  attributes do
    attribute(:utc_day, :date, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:calls, :integer, allow_nil?: false, public?: true)
    # Whether today's first refusal at the cap has been reported.
    attribute(:cap_reported, :boolean, allow_nil?: false, default: false, public?: true)
  end
end
