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

  `wallop_landobs_valid_value` and `wallop_freq_valid_value` back CHECK constraints, so their text is frozen and they call no other function: Postgres neither re-checks stored rows when a function is replaced nor records a dependency between functions.

  The v6 guards read `clock_timestamp()` and check the lock and fetch deadlines again at COMMIT, so a transaction held open until the entropy is known can neither keep a late lock nor fail the draw after its deadline.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type("draw")

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
      :freq_start,
      :freq_value,
      :freq_fallback_reason,
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
      index([:api_key_id, :status, :inserted_at, :id],
        name: "draws_api_key_id_status_inserted_at_id_index"
      )
    end

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
        LANGUAGE sql IMMUTABLE AS $$ SELECT interval '30 minutes' $$
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

      statement :wallop_landobs_valid_value do
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

      statement :wallop_receipt_integer do
        up("""
        CREATE OR REPLACE FUNCTION wallop_receipt_integer(raw text, p jsonb, key text) RETURNS boolean
        LANGUAGE sql IMMUTABLE AS $$
          SELECT jsonb_typeof(p -> key) = 'number'
             AND (p ->> key) ~ '^[1-9][0-9]*$'
             AND (strpos(raw, '"' || key || '":' || (p ->> key) || ',') > 0
                  OR strpos(raw, '"' || key || '":' || (p ->> key) || '}') > 0)
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_receipt_integer(text, jsonb, text)")
      end

      statement :wallop_freq_tag do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_tag() RETURNS text
        LANGUAGE sql IMMUTABLE AS $$ SELECT text 'drand-quicknet+elexon-freq-v1' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_tag()")
      end

      statement :wallop_freq_fetch_window do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_fetch_window() RETURNS interval
        LANGUAGE sql IMMUTABLE AS $$ SELECT interval '240 seconds' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_fetch_window()")
      end

      statement :wallop_freq_span do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_span() RETURNS interval
        LANGUAGE sql IMMUTABLE AS $$ SELECT interval '105 seconds' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_span()")
      end

      statement :wallop_freq_margin do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_margin() RETURNS interval
        LANGUAGE sql IMMUTABLE AS $$ SELECT interval '15 seconds' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_margin()")
      end

      statement :wallop_freq_lock_gap do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_lock_gap() RETURNS interval
        LANGUAGE sql IMMUTABLE AS $$ SELECT interval '60 seconds' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_lock_gap()")
      end

      statement :wallop_freq_stuck_run do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_stuck_run() RETURNS integer
        LANGUAGE sql IMMUTABLE AS $$ SELECT 6 $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_stuck_run()")
      end

      statement :wallop_freq_fallback_reason do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_fallback_reason() RETURNS text
        LANGUAGE sql IMMUTABLE AS $$ SELECT text 'no_frequency_by_deadline' $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_fallback_reason()")
      end

      statement :wallop_freq_start do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_start(drand_round bigint) RETURNS timestamp
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT timestamp '1970-01-01 00:00:00' + interval '1 second' * (x - mod(x, 15))
          FROM (SELECT 1692803367 + (drand_round - 1) * 3
                       - EXTRACT(EPOCH FROM wallop_freq_span() + wallop_freq_fetch_window()
                                            + wallop_freq_margin())::bigint AS x) s
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_start(bigint)")
      end

      statement :wallop_freq_fetch_deadline do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_fetch_deadline(freq_start timestamp) RETURNS timestamp
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT freq_start + wallop_freq_span() + wallop_freq_fetch_window()
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_fetch_deadline(timestamp)")
      end

      statement :wallop_freq_lock_allowed do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_lock_allowed(locked_at timestamp, freq_start timestamp)
        RETURNS boolean
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT locked_at <= freq_start - wallop_freq_lock_gap()
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_lock_allowed(timestamp, timestamp)")
      end

      statement :wallop_freq_valid_value do
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_valid_value(v text) RETURNS boolean
        LANGUAGE plpgsql IMMUTABLE AS $$
        DECLARE
          parts text[];
          run integer := 1;
          n integer;
        BEGIN
          IF v IS NULL OR v !~ '^[0-9]{5}(;[0-9]{5}){7}$' THEN
            RETURN false;
          END IF;
          parts := string_to_array(v, ';');
          FOR i IN 1..8 LOOP
            n := parts[i]::integer;
            IF n < 47000 OR n > 52999 THEN
              RETURN false;
            END IF;
            IF i > 1 AND parts[i] = parts[i - 1] THEN
              run := run + 1;
            ELSE
              run := 1;
            END IF;
            IF run >= 6 THEN
              RETURN false;
            END IF;
          END LOOP;
          RETURN true;
        END;
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_valid_value(text)")
      end

      statement :wallop_v6_lock_keys do
        up("""
        CREATE OR REPLACE FUNCTION wallop_v6_lock_keys() RETURNS text[]
        LANGUAGE sql IMMUTABLE AS $$
          SELECT ARRAY[
            'commitment_hash', 'drand_chain', 'drand_round', 'draw_id',
            'entropy_composition', 'entry_hash', 'fair_pick_version', 'freq_start',
            'jcs_version', 'locked_at', 'operator_id', 'operator_slug', 'schema_version',
            'sequence', 'signature_algorithm', 'signing_key_id', 'wallop_core_version',
            'weather_station', 'weather_time', 'winner_count'
          ]::text[]
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_v6_lock_keys()")
      end

      statement :wallop_v6_exec_keys do
        up("""
        CREATE OR REPLACE FUNCTION wallop_v6_exec_keys() RETURNS text[]
        LANGUAGE sql IMMUTABLE AS $$
          SELECT ARRAY[
            'drand_chain', 'drand_randomness', 'drand_round', 'drand_signature',
            'drand_signature_algorithm', 'draw_id', 'entropy_composition', 'entry_hash',
            'executed_at', 'fair_pick_version', 'freq_fallback_reason', 'freq_value',
            'jcs_version', 'lock_receipt_hash', 'merkle_algorithm', 'operator_id',
            'operator_slug', 'results', 'schema_version', 'seed', 'sequence',
            'signature_algorithm', 'signing_key_id', 'wallop_core_version',
            'weather_fallback_reason', 'weather_observation_time', 'weather_station',
            'weather_value'
          ]::text[]
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_v6_exec_keys()")
      end

      statement :wallop_v6_fetch_deadline do
        up("""
        CREATE OR REPLACE FUNCTION wallop_v6_fetch_deadline(
          entropy_composition text, weather_time timestamp, freq_start timestamp)
        RETURNS timestamp
        LANGUAGE sql IMMUTABLE AS $$
          SELECT CASE
            WHEN entropy_composition = wallop_landobs_tag()
              THEN weather_time + wallop_landobs_fetch_window()
            WHEN entropy_composition = wallop_freq_tag()
              THEN wallop_freq_fetch_deadline(freq_start)
          END
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_v6_fetch_deadline(text, timestamp, timestamp)")
      end

      statement :wallop_check_v6_lock_receipt do
        up("""
        CREATE OR REPLACE FUNCTION wallop_check_v6_lock_receipt(d draws, r operator_receipts)
        RETURNS void
        LANGUAGE plpgsql STABLE AS $$
        DECLARE
          raw text := convert_from(r.payload_jcs, 'UTF8');
          p jsonb := raw::jsonb;
          field text;
          keys text[];
        BEGIN
          IF p->>'schema_version' IS DISTINCT FROM d.lock_schema_version
             OR p->>'entropy_composition' IS DISTINCT FROM d.entropy_composition THEN
            RAISE EXCEPTION 'a v6 lock receipt must carry its draw''s schema and entropy_composition';
          END IF;

          -- Exactly the tag's keys, so no extra or look-alike field rides
          -- along. A duplicate key is not seen here (jsonb keeps the last
          -- value); the verifier refuses it.
          IF d.entropy_composition IS DISTINCT FROM wallop_landobs_tag()
             AND d.entropy_composition IS DISTINCT FROM wallop_freq_tag() THEN
            RAISE EXCEPTION 'no lock receipt rules for entropy_composition %', d.entropy_composition;
          END IF;
          keys := wallop_v6_lock_keys();
          IF jsonb_typeof(p) IS DISTINCT FROM 'object'
             OR (SELECT array_agg(k ORDER BY k COLLATE "C") FROM jsonb_object_keys(p) k)
                IS DISTINCT FROM keys THEN
            RAISE EXCEPTION 'v6 lock receipt keys are not the tag''s key set';
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
          -- Both tags sign freq_start: the window start the drand round
          -- implies, never NULL (a JSON null or a NULL column refuses).
          IF wallop_parse_rfc3339_usec(p->>'freq_start') IS DISTINCT FROM d.freq_start
             OR d.freq_start IS DISTINCT FROM wallop_freq_start(d.drand_round) THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'freq_start';
          END IF;
          IF p->>'signing_key_id' IS DISTINCT FROM r.signing_key_id
             OR NOT EXISTS (SELECT 1 FROM operator_signing_keys k
                            WHERE k.operator_id = d.operator_id AND k.key_id = r.signing_key_id) THEN
            RAISE EXCEPTION 'v6 lock receipt field % does not match the draw', 'signing_key_id';
          END IF;

          -- jsonb compares 7.0 equal to 7, so the integers are typed here:
          -- the verifier refuses anything but a canonical integer.
          FOREACH field IN ARRAY ARRAY['sequence', 'drand_round', 'winner_count'] LOOP
            IF wallop_receipt_integer(raw, p, field) IS NOT TRUE THEN
              RAISE EXCEPTION 'v6 lock receipt field % must be a canonical positive integer', field;
            END IF;
          END LOOP;

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
          ELSIF d.entropy_composition IS NOT DISTINCT FROM wallop_freq_tag() THEN
            IF wallop_freq_lock_allowed(r.locked_at, wallop_freq_start(d.drand_round)) IS NOT TRUE THEN
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
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION guard_v6_draw() RETURNS trigger AS $fn$
          DECLARE
            now_utc timestamp := statement_timestamp() AT TIME ZONE 'UTC';
            obs RECORD;
            win RECORD;
            r operator_receipts%ROWTYPE;
          BEGIN
            -- Every comparison that could meet a NULL is written so that NULL
            -- refuses (IS DISTINCT FROM, IS NOT TRUE), never passes.
            IF TG_OP = 'DELETE' THEN
              IF OLD.status IS DISTINCT FROM 'open'
                 AND (OLD.lock_schema_version IS NOT NULL OR OLD.entropy_composition IS NOT NULL) THEN
                RAISE EXCEPTION 'a v6 draw can''t be deleted once it has left open';
              END IF;
              RETURN OLD;
            END IF;

            -- A draw with no lock schema before or after (a retired forecast
            -- draw, or one that never locked) meets no tag rule: it returns
            -- here. It may never carry the grid-frequency columns.
            IF OLD.lock_schema_version IS NULL AND OLD.entropy_composition IS NULL
               AND NEW.lock_schema_version IS NULL AND NEW.entropy_composition IS NULL THEN
              -- Every lock is a lock schema 6 lock. An open draw with no lock
              -- schema may only stay open or expire: whatever code runs the
              -- UPDATE, it can't lock under the retired forecast method. (A
              -- NULL lock_schema_version with a tag is an unknown pair,
              -- refused below.)
              IF OLD.status = 'open' AND NEW.status NOT IN ('open', 'expired') THEN
                RAISE EXCEPTION 'a draw leaves open only by locking under lock schema 6, or by expiring';
              END IF;
              IF NEW.freq_start IS NOT NULL OR NEW.freq_value IS NOT NULL
                 OR NEW.freq_fallback_reason IS NOT NULL THEN
                RAISE EXCEPTION 'frequency fields are set only on lock schema 6 draws';
              END IF;
              RETURN NEW;
            END IF;

            -- Every read of stored state below (the window or observation a
            -- completion must use, the lock receipt) must see what has
            -- committed, not a snapshot taken earlier in a REPEATABLE READ
            -- or SERIALIZABLE transaction. Draws with no lock schema returned
            -- above.
            IF current_setting('transaction_isolation') IS DISTINCT FROM 'read committed' THEN
              RAISE EXCEPTION 'a v6 write must run under READ COMMITTED isolation';
            END IF;

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
                        AND (NEW.entropy_composition IS NOT DISTINCT FROM wallop_landobs_tag()
                             OR NEW.entropy_composition IS NOT DISTINCT FROM wallop_freq_tag()))) THEN
              RAISE EXCEPTION 'unknown lock_schema_version and entropy_composition pair: (%, %)',
                NEW.lock_schema_version, NEW.entropy_composition;
            END IF;

            -- A grid-frequency draw never carries a weather column, at any
            -- status: its seed has no weather input.
            IF NEW.entropy_composition IS NOT DISTINCT FROM wallop_freq_tag()
               AND (NEW.weather_station IS NOT NULL OR NEW.weather_time IS NOT NULL
                    OR NEW.weather_value IS NOT NULL OR NEW.weather_observation_time IS NOT NULL
                    OR NEW.weather_fallback_reason IS NOT NULL) THEN
              RAISE EXCEPTION 'a grid-frequency draw carries no weather fields';
            END IF;
            IF OLD.status <> 'open' AND NEW.freq_start IS DISTINCT FROM OLD.freq_start THEN
              RAISE EXCEPTION 'freq_start is frozen once a draw has left open';
            END IF;
            IF NEW.status <> 'completed'
               AND (NEW.freq_value IS NOT NULL OR NEW.freq_fallback_reason IS NOT NULL) THEN
              RAISE EXCEPTION 'frequency results are set only when a draw completes';
            END IF;

            -- Whenever a v6 draw leaves open, by any path.
            IF OLD.status = 'open' AND NEW.status <> 'open' AND NEW.lock_schema_version = '6' THEN
              IF NEW.status <> 'awaiting_entropy' THEN
                RAISE EXCEPTION 'a v6 draw leaves open only by locking';
              END IF;

              -- Every lock schema 6 tag is a drand quicknet tag.
              IF NEW.drand_chain IS DISTINCT FROM wallop_quicknet_chain_hash() THEN
                RAISE EXCEPTION 'v6 drand_chain must be the quicknet chain';
              END IF;

              IF NEW.entropy_composition = wallop_landobs_tag() THEN
                IF NEW.drand_round IS NULL OR NEW.drand_round < 1
                   OR NEW.weather_time IS DISTINCT FROM wallop_landobs_weather_time(NEW.drand_round) THEN
                  RAISE EXCEPTION 'v6 weather_time must follow from drand_round';
                END IF;
                IF NEW.weather_station IS DISTINCT FROM wallop_landobs_primary_station() THEN
                  RAISE EXCEPTION 'v6 lock weather_station must be %', wallop_landobs_primary_station();
                END IF;
                IF NEW.freq_start IS DISTINCT FROM wallop_freq_start(NEW.drand_round) THEN
                  RAISE EXCEPTION 'freq_start must follow from drand_round';
                END IF;
                IF wallop_landobs_lock_allowed(clock_timestamp() AT TIME ZONE 'UTC', NEW.weather_time)
                   IS NOT TRUE THEN
                  RAISE EXCEPTION 'v6 lock is too late for this draw time';
                END IF;
              ELSIF NEW.entropy_composition = wallop_freq_tag() THEN
                IF NEW.drand_round IS NULL OR NEW.drand_round < 1
                   OR NEW.freq_start IS DISTINCT FROM wallop_freq_start(NEW.drand_round) THEN
                  RAISE EXCEPTION 'freq_start must follow from drand_round';
                END IF;
                -- Its weather columns are refused above, at every status.
                IF wallop_freq_lock_allowed(clock_timestamp() AT TIME ZONE 'UTC', NEW.freq_start)
                   IS NOT TRUE THEN
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

              IF EXISTS (SELECT 1 FROM execution_receipts WHERE draw_id = NEW.id) THEN
                RAISE EXCEPTION 'a v6 draw can''t lock with an execution receipt already stored';
              END IF;
            END IF;

            -- From pub(R) on the outcome is knowable: failing the draw then would
            -- be a selective abort. Refused from F (chosen by tag), a minute or
            -- more earlier for Land Obs and at least M = 15 s earlier for grid
            -- frequency, so a database clock behind drand's leaves no window.
            -- An unknown tag gives a NULL F, which refuses. Checked here on the
            -- statement's clock and again at commit (check_v6_draw_failed_commit).
            IF (OLD.lock_schema_version IS NOT NULL OR OLD.entropy_composition IS NOT NULL)
               AND NEW.status = 'failed' AND OLD.status IS DISTINCT FROM 'failed'
               AND (now_utc < wallop_v6_fetch_deadline(OLD.entropy_composition, OLD.weather_time,
                                                       OLD.freq_start)) IS NOT TRUE THEN
              RAISE EXCEPTION 'a v6 draw can''t fail once its fetch deadline has passed';
            END IF;

            IF OLD.lock_schema_version = '6' AND OLD.status <> 'completed' AND NEW.status = 'completed' THEN
              IF (NEW.executed_at >= wallop_quicknet_pub_time(OLD.drand_round)) IS NOT TRUE THEN
                RAISE EXCEPTION 'v6 draw cannot complete before its drand round publishes';
              END IF;

              IF OLD.entropy_composition = wallop_landobs_tag() THEN
                -- Exactly one of three states. VOLATILE reads, after this
                -- row's lock, so a store that held it is seen once it ends.
                SELECT station, value, observation_time INTO obs FROM weather_observations
                  WHERE observation_time = OLD.weather_time;
                IF FOUND THEN
                  -- (a) The hour's reading. The window is not consulted,
                  -- even if one is stored.
                  IF NEW.weather_value IS DISTINCT FROM obs.value
                     OR NEW.weather_observation_time IS DISTINCT FROM obs.observation_time
                     OR NEW.weather_fallback_reason IS NOT NULL
                     OR NEW.freq_value IS NOT NULL OR NEW.freq_fallback_reason IS NOT NULL THEN
                    RAISE EXCEPTION 'v6 draw must complete with its stored observation';
                  END IF;
                ELSE
                  -- No reading: the weather falls back, a minute past F, so a
                  -- store that commits at F is visible to every draw first.
                  IF NEW.weather_value IS NOT NULL OR NEW.weather_observation_time IS NOT NULL
                     OR NEW.weather_fallback_reason IS DISTINCT FROM wallop_landobs_fallback_reason()
                     OR (now_utc > OLD.weather_time + wallop_landobs_fetch_window() + interval '1 minute')
                        IS NOT TRUE THEN
                    RAISE EXCEPTION 'v6 draw may fall back only after the fetch deadline with nothing stored';
                  END IF;
                  SELECT value INTO win FROM frequency_windows WHERE freq_start = OLD.freq_start;
                  IF FOUND THEN
                    -- (b) T's window.
                    IF NEW.freq_value IS DISTINCT FROM win.value OR NEW.freq_fallback_reason IS NOT NULL THEN
                      RAISE EXCEPTION 'v6 draw must complete with its stored frequency window';
                    END IF;
                  -- (c) Neither, and M past T's fetch deadline too.
                  ELSIF NEW.freq_value IS NOT NULL
                        OR NEW.freq_fallback_reason IS DISTINCT FROM wallop_freq_fallback_reason()
                        OR (now_utc > wallop_freq_fetch_deadline(OLD.freq_start) + wallop_freq_margin())
                           IS NOT TRUE THEN
                    RAISE EXCEPTION 'v6 draw may fall back only after the fetch deadline with nothing stored';
                  END IF;
                END IF;
              ELSIF OLD.entropy_composition = wallop_freq_tag() THEN
                -- Its weather columns are refused above, at every status.
                -- One row per T: every draw of T completes with it. VOLATILE,
                -- so this read takes a fresh snapshot once a store holding
                -- this row's lock has ended.
                SELECT value INTO win FROM frequency_windows WHERE freq_start = OLD.freq_start;
                IF FOUND THEN
                  IF NEW.freq_value IS DISTINCT FROM win.value OR NEW.freq_fallback_reason IS NOT NULL THEN
                    RAISE EXCEPTION 'v6 draw must complete with its stored frequency window';
                  END IF;
                -- The fallback waits M past F, so a store that commits at F
                -- is visible to every draw of T. Execution is at or after
                -- pub(R) >= F + M anyway.
                ELSIF NEW.freq_value IS NOT NULL
                      OR NEW.freq_fallback_reason IS DISTINCT FROM wallop_freq_fallback_reason()
                      OR (now_utc > wallop_freq_fetch_deadline(OLD.freq_start) + wallop_freq_margin())
                         IS NOT TRUE THEN
                  RAISE EXCEPTION 'v6 draw may fall back only after the fetch deadline with nothing stored';
                END IF;
              ELSE
                RAISE EXCEPTION 'no completion rules for entropy_composition %', OLD.entropy_composition;
              END IF;
            END IF;

            RETURN NEW;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS draws_v6_guard ON draws;
          CREATE TRIGGER draws_v6_guard BEFORE UPDATE OR DELETE ON draws
            FOR EACH ROW EXECUTE FUNCTION guard_v6_draw();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS draws_v6_guard ON draws;
          DROP FUNCTION IF EXISTS guard_v6_draw();
        END
        $do$
        """)
      end

      statement :check_v6_draw_failed_commit do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION check_v6_draw_failed_commit() RETURNS trigger AS $fn$
          BEGIN
            IF (clock_timestamp() AT TIME ZONE 'UTC'
                < wallop_v6_fetch_deadline(NEW.entropy_composition, NEW.weather_time, NEW.freq_start))
               IS NOT TRUE THEN
              RAISE EXCEPTION 'a v6 draw can''t fail once its fetch deadline has passed';
            END IF;

            RETURN NULL;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS draws_v6_failed_commit ON draws;
          CREATE CONSTRAINT TRIGGER draws_v6_failed_commit
            AFTER UPDATE ON draws
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW
            WHEN (NEW.status = 'failed' AND OLD.status IS DISTINCT FROM 'failed'
                  AND (NEW.lock_schema_version IS NOT NULL OR NEW.entropy_composition IS NOT NULL))
            EXECUTE FUNCTION check_v6_draw_failed_commit();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS draws_v6_failed_commit ON draws;
          DROP FUNCTION IF EXISTS check_v6_draw_failed_commit();
        END
        $do$
        """)
      end

      statement :check_v6_draw_completed_commit do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION check_v6_draw_completed_commit() RETURNS trigger AS $fn$
          BEGIN
            IF NOT EXISTS (SELECT 1 FROM execution_receipts WHERE draw_id = NEW.id) THEN
              RAISE EXCEPTION 'a v6 draw must commit its execution receipt with its completion';
            END IF;

            RETURN NULL;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS draws_v6_completed_commit ON draws;
          CREATE CONSTRAINT TRIGGER draws_v6_completed_commit
            AFTER UPDATE ON draws
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW
            WHEN (NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed'
                  AND (NEW.lock_schema_version IS NOT NULL OR NEW.entropy_composition IS NOT NULL))
            EXECUTE FUNCTION check_v6_draw_completed_commit();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS draws_v6_completed_commit ON draws;
          DROP FUNCTION IF EXISTS check_v6_draw_completed_commit();
        END
        $do$
        """)
      end

      statement :check_v6_draw_lock_commit do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION check_v6_draw_lock_commit() RETURNS trigger AS $fn$
          BEGIN
            IF NEW.entropy_composition IS NOT DISTINCT FROM wallop_landobs_tag() THEN
              IF wallop_landobs_lock_allowed(clock_timestamp() AT TIME ZONE 'UTC', NEW.weather_time)
                 IS NOT TRUE THEN
                RAISE EXCEPTION 'v6 lock is too late for this draw time';
              END IF;
            ELSIF NEW.entropy_composition IS NOT DISTINCT FROM wallop_freq_tag() THEN
              IF wallop_freq_lock_allowed(clock_timestamp() AT TIME ZONE 'UTC', NEW.freq_start)
                 IS NOT TRUE THEN
                RAISE EXCEPTION 'v6 lock is too late for this draw time';
              END IF;
            ELSE
              RAISE EXCEPTION 'no lock rules for entropy_composition %', NEW.entropy_composition;
            END IF;

            RETURN NULL;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS draws_v6_lock_commit ON draws;
          CREATE CONSTRAINT TRIGGER draws_v6_lock_commit
            AFTER UPDATE ON draws
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW
            WHEN (OLD.status = 'open' AND NEW.status IS DISTINCT FROM 'open'
                  AND (NEW.lock_schema_version IS NOT NULL OR NEW.entropy_composition IS NOT NULL))
            EXECUTE FUNCTION check_v6_draw_lock_commit();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS draws_v6_lock_commit ON draws;
          DROP FUNCTION IF EXISTS check_v6_draw_lock_commit();
        END
        $do$
        """)
      end

      statement :guard_v6_lock_receipt do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION guard_v6_lock_receipt() RETURNS trigger AS $fn$
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
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS operator_receipts_v6_guard ON operator_receipts;
          CREATE TRIGGER operator_receipts_v6_guard BEFORE INSERT ON operator_receipts
            FOR EACH ROW EXECUTE FUNCTION guard_v6_lock_receipt();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS operator_receipts_v6_guard ON operator_receipts;
          DROP FUNCTION IF EXISTS guard_v6_lock_receipt();
        END
        $do$
        """)
      end

      statement :guard_v6_draw_insert do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION guard_v6_draw_insert() RETURNS trigger AS $fn$
          BEGIN
            IF NEW.lock_schema_version IS NOT NULL OR NEW.entropy_composition IS NOT NULL THEN
              RAISE EXCEPTION 'lock_schema_version and entropy_composition are set only when a draw leaves open';
            END IF;
            IF NEW.status IS DISTINCT FROM 'open' THEN
              RAISE EXCEPTION 'a draw is created open';
            END IF;
            IF NEW.freq_start IS NOT NULL OR NEW.freq_value IS NOT NULL
               OR NEW.freq_fallback_reason IS NOT NULL THEN
              RAISE EXCEPTION 'frequency fields are set only on lock schema 6 draws';
            END IF;
            RETURN NEW;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS draws_v6_insert_guard ON draws;
          CREATE TRIGGER draws_v6_insert_guard BEFORE INSERT ON draws
            FOR EACH ROW EXECUTE FUNCTION guard_v6_draw_insert();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS draws_v6_insert_guard ON draws;
          DROP FUNCTION IF EXISTS guard_v6_draw_insert();
        END
        $do$
        """)
      end

      statement :guard_v6_execution_receipt do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION guard_v6_execution_receipt() RETURNS trigger AS $fn$
          DECLARE
            now_utc timestamp := statement_timestamp() AT TIME ZONE 'UTC';
            d draws%ROWTYPE;
            pair_schema text;
            pair_tag text;
            l operator_receipts%ROWTYPE;
            raw text;
            p jsonb;
            lp jsonb;
            obs RECORD;
            win RECORD;
            win_value text;
            win_stored boolean;
            keys text[];
            stored boolean;
            field text;
            bad text;
          BEGIN
            -- The draw row FOR SHARE, on every path, the forecast one
            -- included. It waits for an in-flight UPDATE of the draw (a lock
            -- or a completion) and then reads the committed row, and it holds
            -- off a later lock until this transaction ends, so the lock's
            -- check for a stored execution receipt sees this one. Under
            -- REPEATABLE READ, a draw changed since the snapshot (a lock
            -- committed after it) makes this a serialization failure, never
            -- a stale NULL pair. A forecast completion inserts its receipt in
            -- the transaction that already holds the row's lock, so this
            -- takes nothing new there.
            SELECT * INTO d FROM draws WHERE id = NEW.draw_id FOR SHARE;
            pair_schema := d.lock_schema_version;
            pair_tag := d.entropy_composition;

            IF pair_schema IS NULL AND pair_tag IS NULL THEN
              BEGIN
                p := convert_from(NEW.payload_jcs, 'UTF8')::jsonb;
              EXCEPTION WHEN others THEN
                RETURN NEW;
              END;
              IF jsonb_typeof(p) = 'object' AND p->>'schema_version' IS NOT DISTINCT FROM '5' THEN
                RAISE EXCEPTION 'a schema 5 execution receipt needs a draw locked under schema 6';
              END IF;
              RETURN NEW;
            END IF;

            -- The stored window or observation (or its absence) is read
            -- below: under REPEATABLE READ or SERIALIZABLE that read could
            -- see a snapshot from before the store committed.
            IF current_setting('transaction_isolation') IS DISTINCT FROM 'read committed' THEN
              RAISE EXCEPTION 'a v6 write must run under READ COMMITTED isolation';
            END IF;

            -- d was read FOR SHARE above. A completed draw can't change after.

            -- The tag's rules, or a refusal: nothing falls through to
            -- another tag.
            IF d.lock_schema_version IS DISTINCT FROM '6'
               OR (d.entropy_composition IS DISTINCT FROM wallop_landobs_tag()
                   AND d.entropy_composition IS DISTINCT FROM wallop_freq_tag()) THEN
              -- The second test is belt and braces: the draws guard lets a
              -- schema 6 draw carry only these two tags. Kept so a tag added
              -- there without rules here is refused, not passed.
              RAISE EXCEPTION 'no execution receipt rules for (%, %)',
                d.lock_schema_version, d.entropy_composition;
            END IF;
            keys := wallop_v6_exec_keys();

            raw := convert_from(NEW.payload_jcs, 'UTF8');
            p := raw::jsonb;

            IF p->>'schema_version' IS DISTINCT FROM '5'
               OR p->>'entropy_composition' IS DISTINCT FROM d.entropy_composition THEN
              RAISE EXCEPTION 'a v6 execution receipt must be schema 5 and carry its draw''s entropy_composition';
            END IF;

            -- Exactly the tag's keys, so no extra or look-alike field rides
            -- along. A duplicate key is not seen here (jsonb keeps the last
            -- value); the verifier refuses it.
            IF jsonb_typeof(p) IS DISTINCT FROM 'object'
               OR (SELECT array_agg(k ORDER BY k COLLATE "C") FROM jsonb_object_keys(p) k)
                  IS DISTINCT FROM keys THEN
              RAISE EXCEPTION 'v6 execution receipt keys are not the tag''s key set';
            END IF;

            IF d.status IS DISTINCT FROM 'completed' THEN
              RAISE EXCEPTION 'a v6 execution receipt needs its draw completed first';
            END IF;

            SELECT * INTO l FROM operator_receipts WHERE draw_id = d.id;
            IF NOT FOUND THEN
              RAISE EXCEPTION 'a v6 execution receipt needs its draw''s lock receipt';
            END IF;
            lp := convert_from(l.payload_jcs, 'UTF8')::jsonb;

            bad := CASE
              WHEN p->>'draw_id' IS DISTINCT FROM d.id::text OR NEW.draw_id IS DISTINCT FROM d.id
                THEN 'draw_id'
              WHEN p->>'operator_id' IS DISTINCT FROM d.operator_id::text
                   OR NEW.operator_id IS DISTINCT FROM d.operator_id
                THEN 'operator_id'
              WHEN p->>'operator_slug' IS DISTINCT FROM (SELECT slug::text FROM operators WHERE id = d.operator_id)
                   OR p->'operator_slug' IS DISTINCT FROM lp->'operator_slug'
                THEN 'operator_slug'
              WHEN p->'sequence' IS DISTINCT FROM to_jsonb(d.operator_sequence)
                   OR NEW.sequence IS DISTINCT FROM d.operator_sequence
                THEN 'sequence'
              WHEN p->>'entry_hash' IS DISTINCT FROM d.entry_hash THEN 'entry_hash'
              WHEN p->>'lock_receipt_hash' IS DISTINCT FROM encode(sha256(l.payload_jcs), 'hex')
                   OR NEW.lock_receipt_hash IS DISTINCT FROM encode(sha256(l.payload_jcs), 'hex')
                THEN 'lock_receipt_hash'
              WHEN jsonb_typeof(p->'fair_pick_version') IS DISTINCT FROM 'string'
                   OR p->'fair_pick_version' IS DISTINCT FROM lp->'fair_pick_version'
                THEN 'fair_pick_version'
              WHEN p->>'drand_chain' IS DISTINCT FROM d.drand_chain
                   OR d.drand_chain IS DISTINCT FROM wallop_quicknet_chain_hash()
                THEN 'drand_chain'
              WHEN p->'drand_round' IS DISTINCT FROM to_jsonb(d.drand_round) THEN 'drand_round'
              WHEN p->>'drand_randomness' IS DISTINCT FROM d.drand_randomness THEN 'drand_randomness'
              WHEN p->>'drand_signature' IS DISTINCT FROM d.drand_signature THEN 'drand_signature'
              WHEN p->>'seed' IS DISTINCT FROM d.seed THEN 'seed'
              WHEN p->'results' IS DISTINCT FROM
                   (SELECT jsonb_agg(x->'entry_id' ORDER BY (x->>'position')::bigint) FROM unnest(d.results) x)
                THEN 'results'
              WHEN wallop_parse_rfc3339_usec(p->>'executed_at') IS DISTINCT FROM d.executed_at
                THEN 'executed_at'
              WHEN p->>'signing_key_id' IS DISTINCT FROM NEW.signing_key_id THEN 'signing_key_id'
            END;
            IF bad IS NOT NULL THEN
              RAISE EXCEPTION 'v6 execution receipt field % does not match the draw', bad;
            END IF;

            -- drand's randomness is sha256 of its BLS signature (both hex,
            -- lower case, as the receipt carries them).
            IF (CASE WHEN p->>'drand_signature' ~ '^([0-9a-f][0-9a-f])+$'
                     THEN encode(sha256(decode(p->>'drand_signature', 'hex')), 'hex') END)
               IS DISTINCT FROM p->>'drand_randomness' THEN
              RAISE EXCEPTION 'v6 execution receipt drand_randomness is not sha256 of drand_signature';
            END IF;

            -- jsonb compares 7.0 equal to 7: the verifier refuses anything but
            -- a canonical integer.
            FOREACH field IN ARRAY ARRAY['sequence', 'drand_round'] LOOP
              IF wallop_receipt_integer(raw, p, field) IS NOT TRUE THEN
                RAISE EXCEPTION 'v6 execution receipt field % must be a canonical positive integer', field;
              END IF;
            END LOOP;

            -- The key must have been in the keyring at executed_at (the
            -- verifier's rule) and eligible to sign by then (the signer's).
            IF NOT EXISTS (SELECT 1 FROM infrastructure_signing_keys k
                           WHERE k.key_id = NEW.signing_key_id
                             AND k.inserted_at <= d.executed_at AND k.valid_from <= d.executed_at) THEN
              RAISE EXCEPTION 'v6 execution receipt signing key was not valid at executed_at';
            END IF;

            IF d.entropy_composition IS NOT DISTINCT FROM wallop_landobs_tag() THEN
              -- Mirrors the completion guard field by field: one of three states.
              SELECT station, value, observation_time INTO obs FROM weather_observations
                WHERE observation_time = d.weather_time;
              stored := FOUND;
              win_stored := false;
              IF stored THEN
                bad := CASE
                  WHEN p->>'weather_station' IS DISTINCT FROM obs.station THEN 'weather_station'
                  WHEN jsonb_typeof(p->'weather_value') IS DISTINCT FROM 'string'
                       OR p->>'weather_value' IS DISTINCT FROM obs.value
                    THEN 'weather_value'
                  WHEN wallop_parse_rfc3339_usec(p->>'weather_observation_time')
                       IS DISTINCT FROM obs.observation_time
                    THEN 'weather_observation_time'
                  WHEN p->'weather_fallback_reason' IS DISTINCT FROM 'null'::jsonb
                    THEN 'weather_fallback_reason'
                  WHEN p->'freq_value' IS DISTINCT FROM 'null'::jsonb THEN 'freq_value'
                  WHEN p->'freq_fallback_reason' IS DISTINCT FROM 'null'::jsonb
                    THEN 'freq_fallback_reason'
                END;
              ELSE
                SELECT value INTO win_value FROM frequency_windows WHERE freq_start = d.freq_start;
                win_stored := FOUND;
                bad := CASE
                  WHEN p->>'weather_station' IS DISTINCT FROM wallop_landobs_primary_station()
                    THEN 'weather_station'
                  WHEN p->'weather_value' IS DISTINCT FROM 'null'::jsonb THEN 'weather_value'
                  WHEN p->'weather_observation_time' IS DISTINCT FROM 'null'::jsonb
                    THEN 'weather_observation_time'
                  WHEN jsonb_typeof(p->'weather_fallback_reason') IS DISTINCT FROM 'string'
                       OR p->>'weather_fallback_reason' IS DISTINCT FROM wallop_landobs_fallback_reason()
                    THEN 'weather_fallback_reason'
                  WHEN win_stored AND (jsonb_typeof(p->'freq_value') IS DISTINCT FROM 'string'
                                       OR p->>'freq_value' IS DISTINCT FROM win_value)
                    THEN 'freq_value'
                  WHEN win_stored AND p->'freq_fallback_reason' IS DISTINCT FROM 'null'::jsonb
                    THEN 'freq_fallback_reason'
                  WHEN NOT win_stored AND p->'freq_value' IS DISTINCT FROM 'null'::jsonb
                    THEN 'freq_value'
                  WHEN NOT win_stored
                       AND (jsonb_typeof(p->'freq_fallback_reason') IS DISTINCT FROM 'string'
                            OR p->>'freq_fallback_reason' IS DISTINCT FROM wallop_freq_fallback_reason())
                    THEN 'freq_fallback_reason'
                END;
              END IF;
              IF bad IS NOT NULL THEN
                RAISE EXCEPTION 'v6 execution receipt field % does not match the stored observation', bad;
              END IF;

              -- Both clocks, as in the completion guard.
              IF NOT stored
                 AND (now_utc > d.weather_time + wallop_landobs_fetch_window() + interval '1 minute')
                     IS NOT TRUE THEN
                RAISE EXCEPTION 'a v6 execution receipt may fall back only after the fetch deadline with nothing stored';
              END IF;
              IF NOT stored AND NOT win_stored
                 AND (now_utc > wallop_freq_fetch_deadline(d.freq_start) + wallop_freq_margin())
                     IS NOT TRUE THEN
                RAISE EXCEPTION 'a v6 execution receipt may fall back only after the fetch deadline with nothing stored';
              END IF;
            ELSIF d.entropy_composition IS NOT DISTINCT FROM wallop_freq_tag() THEN
              -- T's one stored window, or else the fallback rule. No weather
              -- field is set under this tag.
              SELECT value INTO win FROM frequency_windows WHERE freq_start = d.freq_start;
              stored := FOUND;
              IF stored THEN
                bad := CASE
                  WHEN p->'weather_station' IS DISTINCT FROM 'null'::jsonb THEN 'weather_station'
                  WHEN p->'weather_value' IS DISTINCT FROM 'null'::jsonb THEN 'weather_value'
                  WHEN p->'weather_observation_time' IS DISTINCT FROM 'null'::jsonb
                    THEN 'weather_observation_time'
                  WHEN p->'weather_fallback_reason' IS DISTINCT FROM 'null'::jsonb
                    THEN 'weather_fallback_reason'
                  WHEN jsonb_typeof(p->'freq_value') IS DISTINCT FROM 'string'
                       OR p->>'freq_value' IS DISTINCT FROM win.value
                    THEN 'freq_value'
                  WHEN p->'freq_fallback_reason' IS DISTINCT FROM 'null'::jsonb
                    THEN 'freq_fallback_reason'
                END;
              ELSE
                bad := CASE
                  WHEN p->'weather_station' IS DISTINCT FROM 'null'::jsonb THEN 'weather_station'
                  WHEN p->'weather_value' IS DISTINCT FROM 'null'::jsonb THEN 'weather_value'
                  WHEN p->'weather_observation_time' IS DISTINCT FROM 'null'::jsonb
                    THEN 'weather_observation_time'
                  WHEN p->'weather_fallback_reason' IS DISTINCT FROM 'null'::jsonb
                    THEN 'weather_fallback_reason'
                  WHEN p->'freq_value' IS DISTINCT FROM 'null'::jsonb THEN 'freq_value'
                  WHEN jsonb_typeof(p->'freq_fallback_reason') IS DISTINCT FROM 'string'
                       OR p->>'freq_fallback_reason' IS DISTINCT FROM wallop_freq_fallback_reason()
                    THEN 'freq_fallback_reason'
                END;
              END IF;
              IF bad IS NOT NULL THEN
                RAISE EXCEPTION 'v6 execution receipt field % does not match the stored frequency window', bad;
              END IF;

              -- Mirrors the completion guard: nothing stored, and M past F.
              IF NOT stored
                 AND (now_utc > wallop_freq_fetch_deadline(d.freq_start) + wallop_freq_margin())
                     IS NOT TRUE THEN
                RAISE EXCEPTION 'a v6 execution receipt may fall back only after the fetch deadline with nothing stored';
              END IF;
            ELSE
              RAISE EXCEPTION 'no execution receipt rules for (%, %)',
                d.lock_schema_version, d.entropy_composition;
            END IF;

            RETURN NEW;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS execution_receipts_v6_guard ON execution_receipts;
          CREATE TRIGGER execution_receipts_v6_guard BEFORE INSERT ON execution_receipts
            FOR EACH ROW EXECUTE FUNCTION guard_v6_execution_receipt();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS execution_receipts_v6_guard ON execution_receipts;
          DROP FUNCTION IF EXISTS guard_v6_execution_receipt();
        END
        $do$
        """)
      end
    end
  end

  actions do
    defaults([:read])

    read :list do
      description(
        "The caller's draws, oldest first, optionally filtered by status. Keyset-paginated; " <>
          "page[limit] above 100 is reduced to 100. Not a snapshot: a draw created while paging " <>
          "can commit behind a cursor already returned."
      )

      argument :status, :string do
        allow_nil?(true)
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
            "different entry payload returns HTTP 409."
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

      argument :draw_at, :utc_datetime_usec do
        allow_nil?(true)

        description(
          "When the result should be produced (UTC, second " <>
            "precision, on drand quicknet's 3-second grid; any whole minute is). The lock must " <>
            "happen by the observation hour minus 46 minutes (observation weather) or, for grid " <>
            "frequency, 60 seconds before the first of the 8 grid-frequency readings (at least 7 " <>
            "minutes before the result); a later lock is refused with meta.latest_lock_at. Defaults to the " <>
            "earliest allowed time."
        )
      end

      change({WallopCore.Resources.Draw.Changes.ResolveLockSchema, []})
      validate({WallopCore.Resources.Draw.Validations.DrawAt, []})

      change({WallopCore.Resources.Draw.Changes.LockDraw, []})

      change({WallopCore.Resources.Draw.Changes.DeclareEntropyV6, []},
        where: [{WallopCore.Resources.Draw.Validations.EntropyRulesAre, rules: :landobs}]
      )

      change({WallopCore.Resources.Draw.Changes.DeclareEntropyFreq, []},
        where: [{WallopCore.Resources.Draw.Validations.EntropyRulesAre, rules: :freq}]
      )

      change({WallopCore.Resources.Draw.Changes.RecordStageTimestamp, key: "locked_at"})
      change({WallopCore.Resources.Draw.Changes.RecordStageTimestamp, key: "entropy_declared_at"})

      change({WallopCore.Resources.Draw.Changes.SignAndStoreReceipt, []})
    end

    update :transition_to_pending do
      require_atomic?(false)
      filter(expr(status == :awaiting_entropy))
      change(set_attribute(:status, :pending_entropy))
    end

    update :execute_v6 do
      require_atomic?(false)
      filter(expr(status == :pending_entropy and lock_schema_version == "6"))

      argument(:drand_randomness, :string, allow_nil?: false)
      argument(:drand_signature, :string, allow_nil?: false)
      argument(:drand_response, :string, allow_nil?: false)

      validate match(:drand_randomness, ~r/^[0-9a-f]{64}$/) do
        message("must be a 64-character lowercase hex string")
      end

      change({WallopCore.Resources.Draw.Changes.ExecuteV6, []})
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

    policy action([
             :expire,
             :transition_to_pending,
             :execute_v6,
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
          "drand plus the draw's second source, if it used one (seed_source: entropy), or " <>
          "supplied by the caller " <>
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
          "Combined with the entry hash and weather_value or freq_value, if the draw used one, " <>
          "to derive the draw seed."
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
        "The weather value that fed the seed, for Middle Wallop, Hampshire: the Met Office " <>
          "Land Observations reading as \"<t>;<mslp>;<rh>;<vis>\". Null when the draw used no " <>
          "weather."
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

    attribute :freq_start, :utc_datetime_usec do
      description(
        "The time of the first of the 8 GB grid frequency readings (Elexon FREQ, 15 seconds " <>
          "apart). They feed the seed of a grid-frequency draw, and of an observation-weather " <>
          "draw whose Middle Wallop reading was late. Null until the draw locks under lock schema 6."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :freq_value, :string do
      description(
        "The 8 grid frequency readings in mHz, `;`-joined, in time order, when they fed the " <>
          "seed: on a grid-frequency draw, or an observation-weather draw whose Middle Wallop " <>
          "reading was late. Null otherwise."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :freq_fallback_reason, :string do
      description(
        "Why no grid frequency readings were used (`no_frequency_by_deadline`), on a " <>
          "grid-frequency or observation-weather draw that ended on drand alone. Null otherwise."
      )

      allow_nil?(true)
      public?(true)
    end

    attribute :lock_schema_version, :string do
      description(
        "Lock receipt schema this draw was locked under: \"6\" for observation weather " <>
          "and grid frequency, nil for every other draw. Set as the draw leaves open, then frozen."
      )

      allow_nil?(true)
      public?(false)
    end

    attribute :entropy_composition, :string do
      description(
        "The entropy tag this draw was locked under, when lock_schema_version is set " <>
          ~s{("drand-quicknet+metoffice-landobs-v1" or "drand-quicknet+elexon-freq-v1"); } <>
          "nil otherwise. Set as the draw leaves open, then frozen."
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
        "When the result is due: the publication time of the committed drand round. Not " <>
          "signed; derived from drand_round. Null until the draw locks under lock schema 6."
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
