defmodule WallopCore.Resources.WeatherObservation do
  @moduledoc """
  The weather reading for an observation hour, fixed before the drand rounds
  of that hour's draws publish. One row per hour (`observation_time` is
  unique), shared by every observation-weather draw whose `weather_time` is
  that hour. Write-once. With F = observation_time + W, the database decides
  what may be stored:

    * the hour needs at least one observation-weather draw waiting for
      entropy;
    * the primary station only within [observation_time, F - 10 min], the
      backup only within (F - 10 min, F]. These windows are checked on the
      database clock at statement time (statement_timestamp());
    * one row per hour, so a backup can't be stored once the primary is, and
      a second insert for the hour, even a concurrent one, is refused;
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

  # Limits on the store transaction, so it can't be left open. The commit-time
  # check is what enforces F; these keep a stalled writer from holding the
  # hour's draw rows and its index entry for long. Both are 5 s, the same as
  # the grid-frequency store's.
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
        check: "station = ANY (wallop_landobs_stations())",
        message: "is not a station of the observation protocol"
      )
    end

    # SQL for the store. Every constant comes from a wallop_landobs_* function
    # with an Elixir equality test. Comparisons that could meet a NULL are
    # written so that NULL refuses (IS DISTINCT FROM, IS NOT TRUE).
    custom_statements do
      statement :wallop_landobs_observation_allowed do
        # True when `station` may store a reading for `weather_time` at
        # `now_utc`. The insert trigger calls it with the DB clock; tests
        # call it with exact instants.
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_observation_allowed(
          station text, weather_time timestamp, now_utc timestamp)
        RETURNS boolean
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT CASE
            WHEN station = wallop_landobs_primary_station() THEN
              now_utc >= weather_time
              AND now_utc <= weather_time + wallop_landobs_fetch_window() - interval '10 minutes'
            WHEN station = wallop_landobs_backup_station() THEN
              now_utc > weather_time + wallop_landobs_fetch_window() - interval '10 minutes'
              AND now_utc <= weather_time + wallop_landobs_fetch_window()
            ELSE false
          END
        $$
        """)

        down(
          "DROP FUNCTION IF EXISTS wallop_landobs_observation_allowed(text, timestamp, timestamp)"
        )
      end

      statement :guard_weather_observation_insert do
        # One row per observation hour; the unique index on observation_time
        # makes it the only row, so every draw of the hour gets the same
        # station and value. A backup row can't follow a primary one, and a
        # concurrent insert for the hour waits on the index, then fails.
        #
        # The waiting draws of the hour are locked FOR SHARE, which is enough:
        # it conflicts with the row lock a completion UPDATE takes, so a
        # completion waits for this store to end and its guard then reads
        # the store afresh, and a completion already under way makes this
        # insert wait and then not count that draw. Two stores for the hour
        # don't block each other here; the unique index decides between them.
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION guard_weather_observation_insert() RETURNS trigger AS $fn$
          DECLARE
            now_utc timestamp := statement_timestamp() AT TIME ZONE 'UTC';
          BEGIN
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
        # Runs at COMMIT (a deferred constraint trigger), on the wall clock at
        # that moment, not the statement's start: a row whose transaction
        # reaches its commit after F is refused, and nothing is stored.
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
    # The Land Observations response body, byte for byte: not trimmed (Ash
    # trims a :string by default), so the stored bytes are exactly the ones
    # received.
    attribute(:raw, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    # Set by the insert trigger from the database clock.
    attribute(:stored_at, :utc_datetime_usec, allow_nil?: true)
  end

  identities do
    # The hour's single reading. Its unique index is what makes every draw
    # of the hour use the same station and value.
    identity(:one_per_hour, [:observation_time],
      message: "an observation is already stored for this hour"
    )
  end
end
