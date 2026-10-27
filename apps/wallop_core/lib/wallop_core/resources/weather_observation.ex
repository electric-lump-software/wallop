defmodule WallopCore.Resources.WeatherObservation do
  @moduledoc """
  The weather reading for an observation hour, fixed before the drand rounds
  of that hour's draws publish. One row per hour (`observation_time` is
  unique), shared by every observation-weather draw whose `weather_time` is
  that hour. Write-once. With F = observation_time + W, the database decides
  what may be stored:

    * the hour needs at least one observation-weather draw waiting for
      entropy;
    * Middle Wallop only, within [observation_time, F]. This window is
      checked on the database clock at statement time
      (statement_timestamp());
    * one row per hour, so a second insert for the hour, even a concurrent
      one, is refused;
    * the transaction must commit by F: a deferred check at COMMIT, on the
      wall clock then (clock_timestamp()), bounds the commit by F, so no
      insert can be held open until drand publishes and then kept or dropped.

  Both clocks are read in UTC; no timestamptz anywhere. A draw completes with
  its hour's row or, with no row by F, the fallback rule (the draws guard).

  Internal only: every action is forbidden to actors. Store through
  `WallopCore.Weather.Observations.store/2`.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias WallopCore.Repo

  @statement_timeout "5s"
  @idle_in_transaction_timeout "5s"

  postgres do
    table("weather_observations")
    repo(WallopCore.Repo)

    check_constraints do
      check_constraint(:value, "weather_observations_value_grammar",
        check: "wallop_landobs_valid_value(value) IS TRUE",
        message: "does not match the Land Observations value grammar and bounds"
      )

      check_constraint(:station, "weather_observations_station",
        check: "station = wallop_landobs_primary_station()",
        message: "is not the station of the observation protocol"
      )
    end

    custom_statements do
      statement :wallop_landobs_observation_allowed do
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_observation_allowed(
          station text, weather_time timestamp, now_utc timestamp)
        RETURNS boolean
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT station = wallop_landobs_primary_station()
             AND now_utc >= weather_time
             AND now_utc <= weather_time + wallop_landobs_fetch_window()
        $$
        """)

        down(
          "DROP FUNCTION IF EXISTS wallop_landobs_observation_allowed(text, timestamp, timestamp)"
        )
      end

      statement :guard_weather_observation_insert do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION guard_weather_observation_insert() RETURNS trigger AS $fn$
          DECLARE
            now_utc timestamp := statement_timestamp() AT TIME ZONE 'UTC';
          BEGIN
            -- The draws read below, and every completion's read of this
            -- store, must see what has committed: no REPEATABLE READ or
            -- SERIALIZABLE snapshot.
            IF current_setting('transaction_isolation') IS DISTINCT FROM 'read committed' THEN
              RAISE EXCEPTION 'a v6 write must run under READ COMMITTED isolation';
            END IF;

            PERFORM 1 FROM draws
              WHERE weather_time = NEW.observation_time
                AND lock_schema_version = '6'
                AND entropy_composition = wallop_landobs_tag()
                AND status IN ('awaiting_entropy', 'pending_entropy')
              ORDER BY id
              FOR SHARE;

            IF NOT FOUND THEN
              RAISE EXCEPTION 'no observation-weather draw is waiting for this hour';
            END IF;
            IF wallop_landobs_observation_allowed(NEW.station, NEW.observation_time, now_utc) IS NOT TRUE THEN
              RAISE EXCEPTION '% observation outside its window', NEW.station;
            END IF;

            NEW.stored_at := now_utc;
            RETURN NEW;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS weather_observations_guard ON weather_observations;
          CREATE TRIGGER weather_observations_guard BEFORE INSERT ON weather_observations
            FOR EACH ROW EXECUTE FUNCTION guard_weather_observation_insert();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS weather_observations_guard ON weather_observations;
          DROP FUNCTION IF EXISTS guard_weather_observation_insert();
        END
        $do$
        """)
      end

      statement :check_weather_observation_commit do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION check_weather_observation_commit() RETURNS trigger AS $fn$
          BEGIN
            IF (clock_timestamp() AT TIME ZONE 'UTC' <= NEW.observation_time + wallop_landobs_fetch_window())
               IS NOT TRUE THEN
              RAISE EXCEPTION 'an observation must commit by its fetch deadline';
            END IF;

            RETURN NULL;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS weather_observations_commit_deadline ON weather_observations;
          CREATE CONSTRAINT TRIGGER weather_observations_commit_deadline
            AFTER INSERT ON weather_observations
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION check_weather_observation_commit();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS weather_observations_commit_deadline ON weather_observations;
          DROP FUNCTION IF EXISTS check_weather_observation_commit();
        END
        $do$
        """)
      end

      statement :prevent_weather_observation_mutation do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION prevent_weather_observation_mutation() RETURNS trigger AS $fn$
          BEGIN
            RAISE EXCEPTION 'weather observations are write-once';
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS weather_observations_immutable ON weather_observations;
          CREATE TRIGGER weather_observations_immutable BEFORE UPDATE OR DELETE ON weather_observations
            FOR EACH ROW EXECUTE FUNCTION prevent_weather_observation_mutation();
          DROP TRIGGER IF EXISTS weather_observations_no_truncate ON weather_observations;
          CREATE TRIGGER weather_observations_no_truncate BEFORE TRUNCATE ON weather_observations
            EXECUTE FUNCTION prevent_weather_observation_mutation();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS weather_observations_immutable ON weather_observations;
          DROP TRIGGER IF EXISTS weather_observations_no_truncate ON weather_observations;
          DROP FUNCTION IF EXISTS prevent_weather_observation_mutation();
        END
        $do$
        """)
      end
    end
  end

  actions do
    defaults([:read])

    create :store do
      accept([:station, :observation_time, :value, :raw])

      change(
        before_action(fn changeset, _context ->
          Repo.query!("SET LOCAL statement_timeout = '#{@statement_timeout}'")

          Repo.query!(
            "SET LOCAL idle_in_transaction_session_timeout = '#{@idle_in_transaction_timeout}'"
          )

          changeset
        end)
      )
    end
  end

  policies do
    policy action_type([:create, :read]) do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:station, :string, allow_nil?: false)
    attribute(:observation_time, :utc_datetime_usec, allow_nil?: false)
    attribute(:value, :string, allow_nil?: false)
    attribute(:raw, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:stored_at, :utc_datetime_usec, allow_nil?: true)
  end

  identities do
    identity(:one_per_hour, [:observation_time],
      message: "an observation is already stored for this hour"
    )
  end
end
