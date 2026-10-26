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

    # One statement, upserting on the primary key: INSERT ... ON CONFLICT (utc_day) DO UPDATE SET
    # calls = calls + 1 RETURNING calls. No transaction, so it never holds
    # a connection or a row lock beyond the statement.
    create :reserve do
      transaction?(false)
      accept([:utc_day])
      upsert?(true)
      upsert_fields([])
      change(set_attribute(:calls, 1))
      change(atomic_update(:calls, expr(calls + 1)))
    end
  end

  policies do
    policy action_type([:create, :read]) do
      forbid_if(always())
    end
  end

  attributes do
    attribute(:utc_day, :date, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:calls, :integer, allow_nil?: false, public?: true)
  end
end
