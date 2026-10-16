defmodule WallopCore.Resources.Draw do
  @moduledoc """
  A provably fair random draw.

  Draws follow a seven-state lifecycle:
  - **open** — draw created, entries may still be added before locking
  - **locked** — entries committed, waiting for seed or entropy declaration
  - **awaiting_entropy** — entropy sources declared, waiting for beacon data
  - **pending_entropy** — all entropy collected, ready for seed computation and execution
  - **completed** — seed applied, winners determined (terminal, immutable)
  - **failed** — entropy collection or execution failed (terminal, immutable)
  - **expired** — draw was never locked and has been abandoned (terminal, immutable)
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type("draw")

    # Every public attribute, plus expected_result_at. Calculations are not
    # in the JSON by default, so listing the fields is how it gets there.
    default_fields([
      :id,
      :status,
      :name,
      :entry_count,
      :entry_hash,
      :entry_canonical,
      :winner_count,
      :seed,
      :seed_source,
      :seed_json,
      :results,
      :drand_chain,
      :drand_round,
      :drand_randomness,
      :drand_signature,
      :drand_response,
      :weather_station,
      :weather_time,
      :weather_value,
      :weather_raw,
      :weather_observation_time,
      :weather_fallback_reason,
      :callback_url,
      :metadata,
      :check_url,
      :executed_at,
      :failed_at,
      :failure_reason,
      :stage_timestamps,
      :operator_sequence,
      :operator_id,
      :expected_result_at
    ])
  end

  postgres do
    table("draws")
    repo(WallopCore.Repo)

    custom_indexes do
      # GET /draws?status=... oldest first, per key. The existing
      # (api_key_id, inserted_at DESC) index would scan the key's whole history.
      index([:api_key_id, :status, :inserted_at, :id],
        name: "draws_api_key_id_status_inserted_at_id_index"
      )
    end

    # The SQL side of the observation-weather protocol. Every constant mirrors
    # an Elixir one and has an equality test in sql_schedule_property_test.exs:
    # WallopCore.Drand.Quicknet, WallopCore.Weather.Schedule,
    # WallopCore.Weather.Stations and WallopCore.Protocol.Tags.LandObs.
    # Tag-specific functions are named after the source (wallop_landobs_*).
    # Times are `timestamp` holding UTC; "now" is
    # statement_timestamp() AT TIME ZONE 'UTC'; no timestamptz anywhere.
    custom_statements do
      statement :wallop_quicknet_chain_hash do
        up("""
        CREATE OR REPLACE FUNCTION wallop_quicknet_chain_hash() RETURNS text
        LANGUAGE sql IMMUTABLE AS $$
          SELECT text '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971'
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_quicknet_chain_hash()")
      end

      statement :wallop_quicknet_pub_time do
        # pub(R) = genesis + (R - 1) * period, from a timestamp epoch plus an
        # interval, so no timestamptz, and no session time zone, is involved.
        # The factor is a whole number of seconds; PostgreSQL's interval * number
        # takes it as float8, which holds every integer below 2^53 exactly, so
        # the microsecond result is exact.
        up("""
        CREATE OR REPLACE FUNCTION wallop_quicknet_pub_time(drand_round bigint) RETURNS timestamp
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT timestamp '1970-01-01 00:00:00' + interval '1 second' * (1692803367 + (drand_round - 1) * 3)
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_quicknet_pub_time(bigint)")
      end

      statement :wallop_landobs_tag do
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_tag() RETURNS text
        LANGUAGE sql IMMUTABLE AS $$ SELECT text 'drand-quicknet+metoffice-landobs-v1' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_tag()")
      end

      statement :wallop_landobs_fetch_window do
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_fetch_window() RETURNS interval
        LANGUAGE sql IMMUTABLE AS $$ SELECT interval '40 minutes' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_fetch_window()")
      end

      statement :wallop_landobs_lock_offset do
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_lock_offset() RETURNS interval
        LANGUAGE sql IMMUTABLE AS $$ SELECT interval '46 minutes' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_lock_offset()")
      end

      statement :wallop_landobs_primary_station do
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_primary_station() RETURNS text
        LANGUAGE sql IMMUTABLE AS $$ SELECT text 'wmo-03749' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_primary_station()")
      end

      statement :wallop_landobs_stations do
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_stations() RETURNS text[]
        LANGUAGE sql IMMUTABLE AS $$ SELECT ARRAY['wmo-03749', 'wmo-03462']::text[] $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_stations()")
      end

      statement :wallop_landobs_backup_station do
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_backup_station() RETURNS text
        LANGUAGE sql IMMUTABLE AS $$ SELECT text 'wmo-03462' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_backup_station()")
      end

      statement :wallop_landobs_valid_value do
        # WallopCore.Weather.LandObsGrammar.valid_value?/1: the grammar and the
        # bounds frozen by the tag. The CASE keeps the casts from running on
        # text the pattern rejected.
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_valid_value(value text) RETURNS boolean
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT CASE
            WHEN value ~ '^(0|-?[1-9][0-9]{0,2});(0|[1-9][0-9]{0,3});(0|[1-9][0-9]{0,2});(0|[1-9][0-9]{0,4})$'
            THEN split_part(value, ';', 1)::int BETWEEN -900 AND 600
             AND split_part(value, ';', 2)::int BETWEEN 850 AND 1100
             AND split_part(value, ';', 3)::int BETWEEN 0 AND 100
             AND split_part(value, ';', 4)::int BETWEEN 0 AND 10000
            ELSE false
          END
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_valid_value(text)")
      end

      statement :wallop_landobs_fallback_reason do
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_fallback_reason() RETURNS text
        LANGUAGE sql IMMUTABLE AS $$ SELECT text 'no_observation_by_deadline' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_fallback_reason()")
      end

      statement :wallop_landobs_weather_time do
        # The latest whole UTC hour h with h + W + 60s <= pub(drand_round).
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_weather_time(drand_round bigint) RETURNS timestamp
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT date_trunc('hour',
            wallop_quicknet_pub_time(drand_round) - wallop_landobs_fetch_window() - interval '60 seconds')
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_weather_time(bigint)")
      end

      statement :wallop_landobs_lock_allowed do
        # True when a lock at locked_at is in time for weather_time. The guards
        # call it with the DB clock or the signed locked_at; tests with exact instants.
        up("""
        CREATE OR REPLACE FUNCTION wallop_landobs_lock_allowed(locked_at timestamp, weather_time timestamp)
        RETURNS boolean
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT locked_at <= weather_time - wallop_landobs_lock_offset()
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_landobs_lock_allowed(timestamp, timestamp)")
      end

      statement :wallop_parse_rfc3339_usec do
        # The receipts' canonical UTC time string, YYYY-MM-DDTHH:MM:SS.ffffffZ,
        # as a timestamp holding UTC. Anything else (an offset, missing
        # microseconds, 24:00, a leap second, an impossible date) raises
        # rather than be read some other way: the value must print back to
        # exactly the same string.
        up("""
        CREATE OR REPLACE FUNCTION wallop_parse_rfc3339_usec(value text) RETURNS timestamp
        LANGUAGE plpgsql STABLE STRICT AS $$
        DECLARE
          parsed timestamp;
        BEGIN
          IF value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{6}Z$' THEN
            RAISE EXCEPTION 'not a canonical UTC timestamp: %', value;
          END IF;

          BEGIN
            -- A timestamp literal ignores the trailing Z.
            parsed := value::timestamp;
          EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'not a canonical UTC timestamp: %', value;
          END;

          IF to_char(parsed, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') IS DISTINCT FROM value THEN
            RAISE EXCEPTION 'not a canonical UTC timestamp: %', value;
          END IF;

          RETURN parsed;
        END;
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_parse_rfc3339_usec(text)")
      end

      statement :wallop_check_v6_lock_receipt do
        # Raises unless receipt r is the lock receipt of v6 draw d: every
        # signed field with a counterpart on the draw, the receipt row or the
        # operator matches it, and the signed locked_at is in time. Called
        # by both guards, so the result is the same whichever of the lock
        # UPDATE and the receipt INSERT runs first.
        up("""
        CREATE OR REPLACE FUNCTION wallop_check_v6_lock_receipt(d draws, r operator_receipts)
        RETURNS void
        LANGUAGE plpgsql STABLE AS $$
        DECLARE
          p jsonb := convert_from(r.payload_jcs, 'UTF8')::jsonb;
        BEGIN
          IF p->>'schema_version' IS DISTINCT FROM d.lock_schema_version
             OR p->>'entropy_composition' IS DISTINCT FROM d.entropy_composition THEN
            RAISE EXCEPTION 'a v6 lock receipt must carry its draw''s schema and entropy_composition';
          END IF;

          IF wallop_parse_rfc3339_usec(p->>'locked_at') IS DISTINCT FROM r.locked_at THEN
            RAISE EXCEPTION 'receipt locked_at must equal the signed locked_at';
          END IF;

          IF p->>'draw_id' IS DISTINCT FROM d.id::text OR r.draw_id IS DISTINCT FROM d.id THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'draw_id';
          END IF;
          IF p->>'operator_id' IS DISTINCT FROM d.operator_id::text
             OR r.operator_id IS DISTINCT FROM d.operator_id THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'operator_id';
          END IF;
          IF p->>'operator_slug' IS DISTINCT FROM (SELECT slug::text FROM operators WHERE id = d.operator_id) THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'operator_slug';
          END IF;
          IF p->'sequence' IS DISTINCT FROM to_jsonb(d.operator_sequence)
             OR r.sequence IS DISTINCT FROM d.operator_sequence THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'sequence';
          END IF;
          IF p->>'entry_hash' IS DISTINCT FROM d.entry_hash OR r.entry_hash IS DISTINCT FROM d.entry_hash THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'entry_hash';
          END IF;
          IF p->>'commitment_hash' IS DISTINCT FROM d.entry_hash
             OR r.commitment_hash IS DISTINCT FROM d.entry_hash THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'commitment_hash';
          END IF;
          IF p->'winner_count' IS DISTINCT FROM to_jsonb(d.winner_count) THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'winner_count';
          END IF;
          IF p->>'drand_chain' IS DISTINCT FROM d.drand_chain THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'drand_chain';
          END IF;
          IF p->'drand_round' IS DISTINCT FROM to_jsonb(d.drand_round) THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'drand_round';
          END IF;
          IF p->>'weather_station' IS DISTINCT FROM d.weather_station THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'weather_station';
          END IF;
          IF wallop_parse_rfc3339_usec(p->>'weather_time') IS DISTINCT FROM d.weather_time THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'weather_time';
          END IF;
          IF p->>'signing_key_id' IS DISTINCT FROM r.signing_key_id
             OR NOT EXISTS (SELECT 1 FROM operator_signing_keys k
                            WHERE k.operator_id = d.operator_id AND k.key_id = r.signing_key_id) THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'signing_key_id';
          END IF;

          -- The key must have been valid at the signed locked_at: in the
          -- keyring by then (the verifier's rule, inserted_at <= locked_at,
          -- no skew), and eligible to sign by then (the lock path's rule,
          -- valid_from <= locked_at). Operator keys have no revocation.
          IF NOT EXISTS (SELECT 1 FROM operator_signing_keys k
                         WHERE k.operator_id = d.operator_id AND k.key_id = r.signing_key_id
                           AND k.inserted_at <= r.locked_at AND k.valid_from <= r.locked_at) THEN
            RAISE EXCEPTION 'v6 lock receipt signing key was not valid at locked_at';
          END IF;

          IF d.entropy_composition IS NOT DISTINCT FROM wallop_landobs_tag() THEN
            IF wallop_landobs_lock_allowed(r.locked_at, wallop_landobs_weather_time(d.drand_round))
               IS NOT TRUE THEN
              RAISE EXCEPTION 'v6 signed locked_at is too late for this draw time';
            END IF;
          ELSE
            RAISE EXCEPTION 'no lock receipt rules for entropy_composition %', d.entropy_composition;
          END IF;
        END;
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_check_v6_lock_receipt(draws, operator_receipts)")
      end

      statement :guard_v6_draw do
        # Does nothing to a draw whose (lock_schema_version,
        # entropy_composition) is (NULL, NULL), which is every forecast and
        # historic draw, except refuse to set the pair outside a lock.
        # The completion clauses read weather_observations, by the draw's
        # weather_time; PL/pgSQL resolves the table only when a v6 draw
        # completes. The draws row keeps the lock's weather_station (frozen);
        # the reading's station is fixed by the hour's single row, and the
        # execution receipt carries it.
        up("""
        CREATE OR REPLACE FUNCTION guard_v6_draw() RETURNS trigger AS $$
        DECLARE
          now_utc timestamp := statement_timestamp() AT TIME ZONE 'UTC';
          obs RECORD;
          r operator_receipts%ROWTYPE;
        BEGIN
          -- Every comparison that could meet a NULL is written so that NULL
          -- refuses (IS DISTINCT FROM, IS NOT TRUE), never passes.
          IF OLD.status <> 'open'
             AND (NEW.lock_schema_version IS DISTINCT FROM OLD.lock_schema_version
                  OR NEW.entropy_composition IS DISTINCT FROM OLD.entropy_composition) THEN
            RAISE EXCEPTION 'lock_schema_version and entropy_composition are frozen once a draw has left open';
          END IF;

          IF NEW.status = 'open'
             AND (NEW.lock_schema_version IS NOT NULL OR NEW.entropy_composition IS NOT NULL) THEN
            RAISE EXCEPTION 'lock_schema_version and entropy_composition are set only when a draw leaves open';
          END IF;

          IF NOT ((NEW.lock_schema_version IS NULL AND NEW.entropy_composition IS NULL)
                  OR (NEW.lock_schema_version IS NOT DISTINCT FROM '6'
                      AND NEW.entropy_composition IS NOT DISTINCT FROM wallop_landobs_tag())) THEN
            RAISE EXCEPTION 'unknown lock_schema_version and entropy_composition pair: (%, %)',
              NEW.lock_schema_version, NEW.entropy_composition;
          END IF;

          -- Whenever a v6 draw leaves open, by any path.
          IF OLD.status = 'open' AND NEW.status <> 'open' AND NEW.lock_schema_version = '6' THEN
            IF NEW.status <> 'awaiting_entropy' THEN
              RAISE EXCEPTION 'a v6 draw leaves open only by locking';
            END IF;

            IF NEW.entropy_composition = wallop_landobs_tag() THEN
              IF NEW.drand_chain IS DISTINCT FROM wallop_quicknet_chain_hash() THEN
                RAISE EXCEPTION 'v6 drand_chain must be the quicknet chain';
              END IF;
              IF NEW.drand_round IS NULL OR NEW.drand_round < 1
                 OR NEW.weather_time IS DISTINCT FROM wallop_landobs_weather_time(NEW.drand_round) THEN
                RAISE EXCEPTION 'v6 weather_time must follow from drand_round';
              END IF;
              IF NEW.weather_station IS DISTINCT FROM wallop_landobs_primary_station() THEN
                RAISE EXCEPTION 'v6 lock weather_station must be %', wallop_landobs_primary_station();
              END IF;
              IF wallop_landobs_lock_allowed(now_utc, NEW.weather_time) IS NOT TRUE THEN
                RAISE EXCEPTION 'v6 lock is too late for this draw time';
              END IF;
            ELSE
              RAISE EXCEPTION 'no lock rules for entropy_composition %', NEW.entropy_composition;
            END IF;

            -- A receipt inserted before this UPDATE gets the same checks it
            -- would get if inserted after. If that receipt's transaction is
            -- still open, its FOR SHARE lock on this row made this UPDATE wait
            -- before the trigger ran; this function is VOLATILE, so the
            -- SELECT below takes a fresh snapshot and sees it once committed.
            SELECT * INTO r FROM operator_receipts WHERE draw_id = NEW.id;
            IF FOUND THEN
              PERFORM wallop_check_v6_lock_receipt(NEW, r);
            END IF;
          END IF;

          IF OLD.lock_schema_version = '6' AND OLD.status <> 'completed' AND NEW.status = 'completed' THEN
            IF (NEW.executed_at >= wallop_quicknet_pub_time(OLD.drand_round)) IS NOT TRUE THEN
              RAISE EXCEPTION 'v6 draw cannot complete before its drand round publishes';
            END IF;

            IF OLD.entropy_composition = wallop_landobs_tag() THEN
              -- One row per observation hour: every draw of the hour
              -- completes with it. VOLATILE, so this read takes a fresh
              -- snapshot once a store holding this row's lock has ended.
              SELECT station, value, observation_time INTO obs FROM weather_observations
                WHERE observation_time = OLD.weather_time;
              IF FOUND THEN
                IF NEW.weather_value IS DISTINCT FROM obs.value
                   OR NEW.weather_observation_time IS DISTINCT FROM obs.observation_time
                   OR NEW.weather_fallback_reason IS NOT NULL THEN
                  RAISE EXCEPTION 'v6 draw must complete with its stored observation';
                END IF;
              ELSIF NEW.weather_value IS NOT NULL OR NEW.weather_observation_time IS NOT NULL
                    OR NEW.weather_fallback_reason IS DISTINCT FROM wallop_landobs_fallback_reason()
                    OR (now_utc > OLD.weather_time + wallop_landobs_fetch_window()) IS NOT TRUE THEN
                RAISE EXCEPTION 'v6 draw may fall back only after the fetch deadline with nothing stored';
              END IF;
            ELSE
              RAISE EXCEPTION 'no completion rules for entropy_composition %', OLD.entropy_composition;
            END IF;
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)

        down("DROP FUNCTION IF EXISTS guard_v6_draw()")
      end

      statement :draws_v6_guard do
        up("""
        CREATE TRIGGER draws_v6_guard BEFORE UPDATE ON draws
          FOR EACH ROW EXECUTE FUNCTION guard_v6_draw()
        """)

        down("DROP TRIGGER IF EXISTS draws_v6_guard ON draws")
      end

      statement :guard_v6_lock_receipt do
        # Fails closed. A draw with no lock schema (every forecast draw) takes
        # any receipt that is not schema 6, exactly as before. A schema 6
        # receipt needs a v6 draw, and a v6 draw's receipt must pass
        # wallop_check_v6_lock_receipt.
        up("""
        CREATE OR REPLACE FUNCTION guard_v6_lock_receipt() RETURNS trigger AS $$
        DECLARE
          d draws%ROWTYPE;
        BEGIN
          -- FOR SHARE waits for an in-flight UPDATE of the draw (a lock) to
          -- finish and then reads the committed row, so a receipt can't slip
          -- in beside a concurrent lock. It also holds off a later lock
          -- UPDATE until this transaction ends, so the draws guard then sees
          -- this receipt.
          SELECT * INTO d FROM draws WHERE id = NEW.draw_id FOR SHARE;

          IF d.lock_schema_version IS NULL AND d.entropy_composition IS NULL THEN
            IF convert_from(NEW.payload_jcs, 'UTF8')::jsonb->>'schema_version' IS NOT DISTINCT FROM '6' THEN
              RAISE EXCEPTION 'a schema 6 lock receipt needs a draw locked under schema 6';
            END IF;
            RETURN NEW;
          END IF;

          PERFORM wallop_check_v6_lock_receipt(d, NEW);
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)

        down("DROP FUNCTION IF EXISTS guard_v6_lock_receipt()")
      end

      statement :operator_receipts_v6_guard do
        up("""
        CREATE TRIGGER operator_receipts_v6_guard BEFORE INSERT ON operator_receipts
          FOR EACH ROW EXECUTE FUNCTION guard_v6_lock_receipt()
        """)

        down("DROP TRIGGER IF EXISTS operator_receipts_v6_guard ON operator_receipts")
      end

      statement :guard_v6_draw_insert do
        # A draw is created open, so it never starts with a lock schema.
        up("""
        CREATE OR REPLACE FUNCTION guard_v6_draw_insert() RETURNS trigger AS $$
        BEGIN
          IF NEW.lock_schema_version IS NOT NULL OR NEW.entropy_composition IS NOT NULL THEN
            RAISE EXCEPTION 'lock_schema_version and entropy_composition are set only when a draw leaves open';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)

        down("DROP FUNCTION IF EXISTS guard_v6_draw_insert()")
      end

      statement :draws_v6_insert_guard do
        up("""
        CREATE TRIGGER draws_v6_insert_guard BEFORE INSERT ON draws
          FOR EACH ROW EXECUTE FUNCTION guard_v6_draw_insert()
        """)

        down("DROP TRIGGER IF EXISTS draws_v6_insert_guard ON draws")
      end
    end
  end

  actions do
    defaults([:read])

    # Many draws in one call. :read is unchanged; GET /draws moves here.
    read :list do
      description(
        "The caller's draws, oldest first, optionally filtered by status. Keyset-paginated; " <>
          "page[limit] above 100 is reduced to 100. Not a snapshot: a draw created while paging " <>
          "can commit behind a cursor already returned."
      )

      argument :status, :string do
        allow_nil?(true)
        # Keep "" as "" (not nil) so `?status=` is rejected, not ignored.
        constraints(allow_empty?: true, trim?: false)

        description(
          "Comma-separated statuses (open, locked, awaiting_entropy, pending_entropy, completed, failed, expired), e.g. `awaiting_entropy,pending_entropy`."
        )
      end

      pagination(keyset?: true, required?: true, default_limit: 50, max_page_size: 100)
      prepare(build(sort: [inserted_at: :asc, id: :asc]))
      prepare({WallopCore.Resources.Draw.Preparations.FilterByStatus, []})
    end

    create :create do
      accept([:name, :winner_count, :metadata, :callback_url, :check_url])

      validate({WallopCore.Resources.Draw.Validations.RequireOperator, []})

      change(set_attribute(:api_key_id, actor(:id)))
      change(set_attribute(:status, :open))
      change({WallopCore.Resources.Draw.Changes.AssignOperatorSequence, []})
      change({WallopCore.Resources.Draw.Changes.ValidateCallbackUrl, []})
      change({WallopCore.Resources.Draw.Changes.ValidateCheckUrl, []})
      change({WallopCore.Resources.Draw.Changes.RecordStageTimestamp, key: "opened_at"})
      change({WallopCore.Resources.Draw.Changes.BroadcastUpdate, []})
    end

    update :add_entries do
      require_atomic?(false)
      filter(expr(status == :open))

      argument :entries, {:array, :map} do
        allow_nil?(false)

        # Map shape is documented here so it surfaces in the generated
        # OpenAPI schema rather than appearing as a bare "array of objects".
        # ValidateEntries and AddEntries enforce the same rules at runtime.
        constraints(
          items: [
            fields: [
              weight: [
                type: :integer,
                allow_nil?: false,
                description:
                  "Weighting for this entry. Positive integer, max 1000. " <>
                    "Higher weight increases selection probability proportionally."
              ]
            ]
          ]
        )
      end

      argument :client_ref, :string do
        allow_nil?(false)

        constraints(min_length: 1, max_length: 256)

        description(
          "Operator-supplied opaque idempotency token for this batch. " <>
            "1..256 bytes. Use a UUID or other high-entropy random value. " <>
            "Do NOT use semantically meaningful or guessable identifiers — " <>
            "the value is hashed at the request boundary but the digest is " <>
            "persisted, and weak inputs are theoretically rainbow-table-able. " <>
            "Retrying with the same (draw_id, client_ref) replays the " <>
            "original response. Re-using the same client_ref against a " <>
            "different entry payload returns HTTP 409. See ADR-0012."
        )
      end

      change({WallopCore.Resources.Draw.Changes.ValidateEntries, []})
      change({WallopCore.Resources.Draw.Changes.HashAndClearClientRef, []})
      change({WallopCore.Resources.Draw.Changes.CheckIdempotency, []})
      change({WallopCore.Resources.Draw.Changes.AddEntries, []})
    end

    update :remove_entry do
      require_atomic?(false)
      filter(expr(status == :open))

      argument :entry_uuid, :string do
        allow_nil?(false)
      end

      change({WallopCore.Resources.Draw.Changes.RemoveEntry, []})
    end

    update :update_name do
      require_atomic?(false)
      filter(expr(status == :open))

      accept([:name])
      change({WallopCore.Resources.Draw.Changes.BroadcastUpdate, []})
    end

    update :update_winner_count do
      require_atomic?(false)
      filter(expr(status == :open))

      accept([:winner_count])
      change({WallopCore.Resources.Draw.Changes.BroadcastUpdate, []})
    end

    update :lock do
      require_atomic?(false)
      filter(expr(status == :open))

      argument :weather_time, :utc_datetime_usec do
        allow_nil?(true)

        description(
          "Optional explicit weather observation time (UTC). When supplied, " <>
            "the entropy worker will fire at this moment and the supplied " <>
            "value is signed verbatim into the lock receipt. If omitted, " <>
            "defaults to a jittered 3-5 minutes from lock-time. Must have " <>
            "second precision (sub-second values rejected — what you supply " <>
            "is what gets signed). Must be at least 60 seconds in the future " <>
            "and within ~7 days. The drand round derivation flows from this " <>
            "value; supplying a far-future weather_time correctly schedules " <>
            "the drand reveal to align."
        )
      end

      validate({WallopCore.Resources.Draw.Validations.WeatherTime, []})

      change({WallopCore.Resources.Draw.Changes.LockDraw, []})
      change({WallopCore.Resources.Draw.Changes.DeclareEntropy, []})
      change({WallopCore.Resources.Draw.Changes.RecordStageTimestamp, key: "locked_at"})
      change({WallopCore.Resources.Draw.Changes.RecordStageTimestamp, key: "entropy_declared_at"})
      change({WallopCore.Resources.Draw.Changes.SignAndStoreReceipt, []})
    end

    update :transition_to_pending do
      require_atomic?(false)
      filter(expr(status == :awaiting_entropy))
      change(set_attribute(:status, :pending_entropy))
    end

    update :execute_with_entropy do
      require_atomic?(false)
      filter(expr(status == :pending_entropy))

      argument(:drand_randomness, :string, allow_nil?: false)
      argument(:drand_signature, :string, allow_nil?: false)
      argument(:drand_response, :string, allow_nil?: false)
      argument(:weather_value, :string, allow_nil?: false)
      argument(:weather_raw, :string, allow_nil?: false)
      argument(:weather_observation_time, :utc_datetime_usec, allow_nil?: false)

      validate match(:drand_randomness, ~r/^[0-9a-f]{64}$/) do
        message("must be a 64-character lowercase hex string")
      end

      change({WallopCore.Resources.Draw.Changes.ExecuteWithEntropy, []})
      change({WallopCore.Resources.Draw.Changes.SignAndStoreExecutionReceipt, []})
      change({WallopCore.Resources.Draw.Changes.EnqueueWebhook, []})
      change({WallopCore.Resources.Draw.Changes.BroadcastUpdate, []})
    end

    update :execute_drand_only do
      require_atomic?(false)
      filter(expr(status == :pending_entropy))

      argument(:drand_randomness, :string, allow_nil?: false)
      argument(:drand_signature, :string, allow_nil?: false)
      argument(:drand_response, :string, allow_nil?: false)
      argument(:weather_fallback_reason, :string, allow_nil?: false)

      validate match(:drand_randomness, ~r/^[0-9a-f]{64}$/) do
        message("must be a 64-character lowercase hex string")
      end

      change({WallopCore.Resources.Draw.Changes.ExecuteDrandOnly, []})
      change({WallopCore.Resources.Draw.Changes.RecordStageTimestamp, key: "executed_at"})
      change({WallopCore.Resources.Draw.Changes.SignAndStoreExecutionReceipt, []})
      change({WallopCore.Resources.Draw.Changes.EnqueueWebhook, []})
      change({WallopCore.Resources.Draw.Changes.BroadcastUpdate, []})
    end

    update :expire do
      require_atomic?(false)
      filter(expr(status == :open))
      change(set_attribute(:status, :expired))
      change({WallopCore.Resources.Draw.Changes.EnqueueWebhook, []})
      change({WallopCore.Resources.Draw.Changes.BroadcastUpdate, []})
    end

    update :mark_failed do
      require_atomic?(false)
      filter(expr(status in [:pending_entropy, :awaiting_entropy]))

      argument(:failure_reason, :string, allow_nil?: false)

      change(set_attribute(:status, :failed))
      change(set_attribute(:failed_at, &DateTime.utc_now/0))

      change(fn changeset, _context ->
        reason = Ash.Changeset.get_argument(changeset, :failure_reason)
        Ash.Changeset.force_change_attribute(changeset, :failure_reason, reason)
      end)

      change({WallopCore.Resources.Draw.Changes.ReportFailure, []})
      change({WallopCore.Resources.Draw.Changes.EnqueueWebhook, []})
      change({WallopCore.Resources.Draw.Changes.BroadcastUpdate, []})
    end
  end

  policies do
    policy action(:create) do
      authorize_if(actor_present())
    end

    policy action(:add_entries) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :open))
    end

    policy action(:remove_entry) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :open))
    end

    policy action(:update_name) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :open))
    end

    policy action(:update_winner_count) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :open))
    end

    policy action(:lock) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :open))
    end

    policy action([:read, :list]) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id)))
    end

    # Internal-only actions: called by EntropyWorker / ExpiryWorker with
    # authorize?: false. Forbidden for all authorized callers to prevent
    # external actors from racing the workers (or, in :expire's case, from
    # burning operator sequence slots maliciously).
    policy action([
             :expire,
             :transition_to_pending,
             :execute_with_entropy,
             :execute_drand_only,
             :mark_failed
           ]) do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :status, :atom do
      description(
        "Current lifecycle state of the draw. Progresses through: open → locked → " <>
          "awaiting_entropy → pending_entropy → completed. Terminal states: failed, expired."
      )

      constraints(
        one_of: [
          :open,
          :locked,
          :awaiting_entropy,
          :pending_entropy,
          :completed,
          :failed,
          :expired
        ]
      )

      default(:open)
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      description(
        "Optional human-readable label for the draw. May only be set or changed while the draw is open."
      )

      allow_nil?(true)
      public?(true)
      constraints(max_length: 255)
    end

    attribute :entry_count, :integer do
      description(
        "Number of entries in this draw. Updated atomically when entries are added or removed."
      )

      allow_nil?(false)
      default(0)
      public?(true)
    end

    attribute :entry_hash, :string do
      description(
        "SHA-256 hash of the canonicalised entry list (JCS). Published at lock time as a " <>
          "cryptographic commitment. Changing any entry would produce a different hash."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :entry_canonical, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :winner_count, :integer do
      description(
        "Number of winners to select. Must be between 1 and 10,000 and no greater than " <>
          "the number of entries."
      )

      allow_nil?(false)
      public?(true)
      constraints(min: 1, max: 10_000)
    end

    attribute :seed, :string do
      description(
        "64-character hex SHA-256 seed used to drive the draw algorithm. Derived from " <>
          "drand + weather entropy (seed_source: entropy) or supplied by the caller " <>
          "(seed_source: caller). Sandbox draws live in a separate resource — see " <>
          "`WallopCore.Resources.SandboxDraw`."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :seed_source, :atom do
      constraints(one_of: [:caller, :entropy])
      allow_nil?(true)
      public?(true)
    end

    attribute :seed_json, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :results, {:array, :map} do
      description(
        "Ordered list of winning entries, populated after draw execution. Each element " <>
          "mirrors the entry structure submitted."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :drand_chain, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :drand_round, :integer do
      description(
        "The drand quicknet beacon round number used as entropy. Declared at lock time " <>
          "before the round resolves — the value is unpredictable at commitment time."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :drand_randomness, :string do
      description(
        "The 64-character hex random value published by drand for the declared round. " <>
          "Combined with weather_value to derive the draw seed."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :drand_signature, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :drand_response, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :weather_station, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :weather_time, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :weather_value, :string do
      description(
        "Temperature observation (°C) from the Middle Wallop, Hampshire Met Office station, " <>
          "taken at the declared observation time. Combined with drand_randomness to derive " <>
          "the draw seed."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :weather_raw, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :weather_observation_time, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :weather_fallback_reason, :string do
      description("Why weather entropy was unavailable. Null when weather was used.")
      allow_nil?(true)
      public?(true)
    end

    attribute :lock_schema_version, :string do
      description(
        "Lock receipt schema this draw was locked under: \"6\" for observation weather, " <>
          "nil for every other draw. Set as the draw leaves open, then frozen."
      )

      allow_nil?(true)
      public?(false)
    end

    attribute :entropy_composition, :string do
      description(
        "The entropy tag this draw was locked under, when lock_schema_version is set " <>
          "(\"drand-quicknet+metoffice-landobs-v1\" today); nil otherwise. Set as the " <>
          "draw leaves open, then frozen."
      )

      allow_nil?(true)
      public?(false)
    end

    attribute :callback_url, :string do
      description(
        "Optional HTTPS URL to receive a webhook POST when the draw completes or fails. " <>
          "Must be a valid HTTPS URL."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :metadata, :map do
      description(
        "Arbitrary JSON object stored with the draw. Not used in seed computation. Useful " <>
          "for storing external references (e.g. your internal draw ID)."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :check_url, :string do
      description(
        "Optional HTTPS URL to the operator's own \"check your ticket\" page. " <>
          "Rendered as an outbound link on the public proof page when a user " <>
          "checks a non-winning UUID — lets operators offer richer-than-flat- " <>
          "boolean lookup (e.g. confirm an entry was submitted, show position) " <>
          "which wallop itself does not provide publicly. " <>
          "Must be ≤ 2048 characters, must be `https://`, and must not " <>
          "contain whitespace. `javascript:`, `data:`, `file:`, `vbscript:`, " <>
          "and other non-https schemes are rejected. " <>
          "Note: `check_url` is display metadata, not part of the signed " <>
          "receipt or entry_hash — operators can point the URL's DNS " <>
          "elsewhere later. Treat it as operator-mutable-in-effect."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :executed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :failed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :failure_reason, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :stage_timestamps, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :operator_sequence, :integer do
      description(
        "Per-operator monotonic sequence number assigned at create time. " <>
          "Gap-free by design — discarded slots are visible."
      )

      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  calculations do
    calculate :expected_result_at,
              :utc_datetime_usec,
              WallopCore.Resources.Draw.Calculations.ExpectedResultAt do
      description(
        "Observation-weather draws only: when the result is due (the publication time of the " <>
          "committed drand round). Not signed; derived from drand_round. Null for other draws."
      )

      public?(true)
    end
  end

  relationships do
    belongs_to :api_key, WallopCore.Resources.ApiKey do
      allow_nil?(false)
      public?(false)
    end

    belongs_to :operator, WallopCore.Resources.Operator do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end

    has_many :entry_records, WallopCore.Resources.Entry do
      destination_attribute(:draw_id)
    end

    has_one :receipt, WallopCore.Resources.OperatorReceipt do
      destination_attribute(:draw_id)
    end

    has_one :execution_receipt, WallopCore.Resources.ExecutionReceipt do
      destination_attribute(:draw_id)
    end
  end
end
