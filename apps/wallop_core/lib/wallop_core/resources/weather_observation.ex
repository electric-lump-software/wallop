defmodule WallopCore.Resources.WeatherObservation do
  @moduledoc """
  The weather reading fixed for an observation-weather draw before its drand
  round publishes. Write-once. Database triggers decide what may be stored,
  with F = weather_time + W:

    * the primary station only within [weather_time, F - 10 min];
    * the backup station only within (F - 10 min, F];
    * nothing once a reading is stored for the draw, and nothing after F;
    * one value per (station, hour): every draw of the hour gets the same one;
    * the row must commit by F on the database clock (a deferred check at
      commit), so no insert can be held open until drand publishes and then
      kept or dropped.

  The statement-time window uses statement_timestamp(); the commit-time check
  uses clock_timestamp(). Both are read in UTC; no timestamptz anywhere.

  Execution reads whatever is stored. Internal only: every action is
  forbidden to actors. Store through `WallopCore.Weather.Observations.store/3`.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias WallopCore.Repo

  # Limits on the store transaction, so it can't be left open. The commit-time
  # check is what enforces F; these keep a stalled writer from holding the
  # draw's row lock (and the hour's lock) for long.
  @statement_timeout "5s"
  @idle_in_transaction_timeout "10s"

  postgres do
    table("weather_observations")
    repo(WallopCore.Repo)

    references do
      reference(:draw, on_delete: :nothing)
    end

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
        # The draw's row is locked FOR UPDATE, so a store and the draw's
        # completion run one after the other: the completion guard, waiting on
        # this lock, then reads the store with a fresh snapshot. The advisory
        # lock on (station, hour) does the same for two draws of one hour, so
        # the one-value check always sees the other's committed row.
        up("""
        CREATE OR REPLACE FUNCTION guard_weather_observation_insert() RETURNS trigger AS $$
        DECLARE
          now_utc timestamp := statement_timestamp() AT TIME ZONE 'UTC';
          d RECORD;
        BEGIN
          SELECT status, weather_time, lock_schema_version, entropy_composition INTO d
            FROM draws WHERE id = NEW.draw_id FOR UPDATE;

          IF NOT FOUND OR d.lock_schema_version IS DISTINCT FROM '6' THEN
            RAISE EXCEPTION 'weather observations are stored only for v6 draws';
          END IF;
          IF d.entropy_composition IS DISTINCT FROM wallop_landobs_tag() THEN
            RAISE EXCEPTION 'no observation rules for entropy_composition %', d.entropy_composition;
          END IF;
          IF d.status IS DISTINCT FROM 'awaiting_entropy' AND d.status IS DISTINCT FROM 'pending_entropy' THEN
            RAISE EXCEPTION 'draw is not waiting for entropy';
          END IF;
          IF NEW.observation_time IS DISTINCT FROM d.weather_time THEN
            RAISE EXCEPTION 'observation_time must equal the draw''s weather_time';
          END IF;

          PERFORM pg_advisory_xact_lock(hashtextextended(
            'weather_observations|' || NEW.station || '|'
              || to_char(NEW.observation_time, 'YYYY-MM-DD"T"HH24:MI:SS.US'), 0));

          IF EXISTS (SELECT 1 FROM weather_observations WHERE draw_id = NEW.draw_id) THEN
            RAISE EXCEPTION 'an observation is already stored for this draw';
          END IF;
          IF EXISTS (SELECT 1 FROM weather_observations
                     WHERE station = NEW.station AND observation_time = NEW.observation_time
                       AND value IS DISTINCT FROM NEW.value) THEN
            RAISE EXCEPTION 'a different value is already stored for this station and hour';
          END IF;
          IF wallop_landobs_observation_allowed(NEW.station, d.weather_time, now_utc) IS NOT TRUE THEN
            RAISE EXCEPTION '% observation outside its window', NEW.station;
          END IF;

          NEW.stored_at := now_utc;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)

        down("DROP FUNCTION IF EXISTS guard_weather_observation_insert()")
      end

      statement :weather_observations_guard do
        up("""
        CREATE TRIGGER weather_observations_guard BEFORE INSERT ON weather_observations
          FOR EACH ROW EXECUTE FUNCTION guard_weather_observation_insert()
        """)

        down("DROP TRIGGER IF EXISTS weather_observations_guard ON weather_observations")
      end

      statement :check_weather_observation_commit do
        # Runs at COMMIT (a deferred constraint trigger), on the wall clock at
        # that moment, not the statement's start: a row whose transaction
        # reaches its commit after F is refused, and nothing is stored.
        up("""
        CREATE OR REPLACE FUNCTION check_weather_observation_commit() RETURNS trigger AS $$
        DECLARE
          d RECORD;
        BEGIN
          SELECT weather_time, entropy_composition INTO d FROM draws WHERE id = NEW.draw_id;

          IF d.entropy_composition IS NOT DISTINCT FROM wallop_landobs_tag() THEN
            IF (clock_timestamp() AT TIME ZONE 'UTC' <= d.weather_time + wallop_landobs_fetch_window())
               IS NOT TRUE THEN
              RAISE EXCEPTION 'an observation must commit by its fetch deadline';
            END IF;
          ELSE
            RAISE EXCEPTION 'no observation rules for entropy_composition %', d.entropy_composition;
          END IF;

          RETURN NULL;
        END;
        $$ LANGUAGE plpgsql
        """)

        down("DROP FUNCTION IF EXISTS check_weather_observation_commit()")
      end

      statement :weather_observations_commit_deadline do
        up("""
        CREATE CONSTRAINT TRIGGER weather_observations_commit_deadline
          AFTER INSERT ON weather_observations
          DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION check_weather_observation_commit()
        """)

        down(
          "DROP TRIGGER IF EXISTS weather_observations_commit_deadline ON weather_observations"
        )
      end

      statement :prevent_weather_observation_mutation do
        up("""
        CREATE OR REPLACE FUNCTION prevent_weather_observation_mutation() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'weather observations are write-once';
        END;
        $$ LANGUAGE plpgsql
        """)

        down("DROP FUNCTION IF EXISTS prevent_weather_observation_mutation()")
      end

      statement :weather_observations_immutable do
        up("""
        CREATE TRIGGER weather_observations_immutable BEFORE UPDATE OR DELETE ON weather_observations
          FOR EACH ROW EXECUTE FUNCTION prevent_weather_observation_mutation()
        """)

        down("DROP TRIGGER IF EXISTS weather_observations_immutable ON weather_observations")
      end

      statement :weather_observations_no_truncate do
        up("""
        CREATE TRIGGER weather_observations_no_truncate BEFORE TRUNCATE ON weather_observations
          EXECUTE FUNCTION prevent_weather_observation_mutation()
        """)

        down("DROP TRIGGER IF EXISTS weather_observations_no_truncate ON weather_observations")
      end
    end
  end

  actions do
    defaults([:read])

    create :store do
      accept([:draw_id, :station, :observation_time, :value, :raw])

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
    attribute(:draw_id, :uuid, allow_nil?: false)
    attribute(:station, :string, allow_nil?: false)
    attribute(:observation_time, :utc_datetime_usec, allow_nil?: false)
    attribute(:value, :string, allow_nil?: false)
    attribute(:raw, :string, allow_nil?: false)
    # Set by the insert trigger from the database clock.
    attribute(:stored_at, :utc_datetime_usec, allow_nil?: true)
  end

  relationships do
    belongs_to :draw, WallopCore.Resources.Draw do
      attribute_writable?(true)
      define_attribute?(false)
      source_attribute(:draw_id)
    end
  end

  identities do
    identity(:one_per_draw, [:draw_id])
  end
end
