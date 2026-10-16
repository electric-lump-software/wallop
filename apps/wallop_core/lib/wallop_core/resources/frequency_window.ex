defmodule WallopCore.Resources.FrequencyWindow do
  @moduledoc """
  The 8 GB grid frequency readings of one window start T, fixed before the
  drand rounds of T's draws publish. One row per T (`freq_start` is
  unique), shared by every grid-frequency draw whose `freq_start` is T.
  Write-once. With F = T + 105 s + W_freq, the database decides what may be
  stored:

    * T needs at least one grid-frequency draw waiting for entropy;
    * only within [T + 105 s, F], on the database clock at statement time
      (statement_timestamp());
    * one row per T: a second insert, even a concurrent one, waits on the
      unique index and is refused;
    * the value must match the grammar, the bounds and the stuck rule
      (`wallop_freq_valid_value`, frozen), and T must sit on the 15 s grid;
    * the transaction must commit by F: a deferred check at COMMIT, on the
      wall clock then (clock_timestamp()), so no insert can be held open
      until drand publishes and then kept or dropped.
    * the transaction must be READ COMMITTED, as must every v6 draw update
      and v6 execution receipt insert, so no guard decides on a snapshot
      taken before a store committed.

  Both clocks are read in UTC; no timestamptz anywhere. A draw completes
  with T's row or, with no row by F + M, the fallback rule (the draws
  guard).

  Internal only: every action is forbidden to actors. Store through
  `WallopCore.Frequency.Windows.store/3`.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias WallopCore.Repo

  # Limits on the store transaction, so it can't be left open. The
  # commit-time check is what enforces F; these keep a stalled writer from
  # holding T's draw rows and its index entry for long. Both are 5 s, the
  # same as the weather store's.
  @statement_timeout "5s"
  @idle_in_transaction_timeout "5s"

  postgres do
    table("frequency_windows")
    repo(WallopCore.Repo)

    check_constraints do
      check_constraint(:value, "frequency_windows_value_grammar",
        check: "wallop_freq_valid_value(value) IS TRUE",
        message: "does not match the grid-frequency value grammar, bounds and stuck rule"
      )

      check_constraint(:freq_start, "frequency_windows_on_grid",
        check:
          "freq_start = date_trunc('second', freq_start) " <>
            "AND mod(EXTRACT(EPOCH FROM freq_start)::bigint, 15) = 0",
        message: "must be a whole multiple of 15 seconds"
      )
    end

    # SQL for the store. Every constant comes from a wallop_freq_* function
    # with an Elixir equality test. Comparisons that could meet a NULL are
    # written so that NULL refuses.
    custom_statements do
      statement :wallop_freq_store_allowed do
        # True when T's window may be stored at now_utc: [T + 105 s, F].
        up("""
        CREATE OR REPLACE FUNCTION wallop_freq_store_allowed(freq_start timestamp, now_utc timestamp)
        RETURNS boolean
        LANGUAGE sql IMMUTABLE STRICT AS $$
          SELECT now_utc >= freq_start + wallop_freq_span()
             AND now_utc <= wallop_freq_fetch_deadline(freq_start)
        $$
        """)

        down("DROP FUNCTION IF EXISTS wallop_freq_store_allowed(timestamp, timestamp)")
      end

      statement :guard_frequency_window_insert do
        # One row per T; the unique index on freq_start makes it the only
        # row, so every draw of T gets the same value. The waiting draws of
        # T are locked FOR SHARE in id order: a completion UPDATE then waits
        # for this store to end and its guard reads the store afresh, and a
        # completion already under way makes this insert wait and then not
        # count that draw.
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION guard_frequency_window_insert() RETURNS trigger AS $fn$
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
              WHERE freq_start = NEW.freq_start
                AND lock_schema_version = '6'
                AND entropy_composition = wallop_freq_tag()
                AND status IN ('awaiting_entropy', 'pending_entropy')
              ORDER BY id
              FOR SHARE;

            IF NOT FOUND THEN
              RAISE EXCEPTION 'no grid-frequency draw is waiting for this window';
            END IF;
            IF wallop_freq_store_allowed(NEW.freq_start, now_utc) IS NOT TRUE THEN
              RAISE EXCEPTION 'frequency window outside its fetch window';
            END IF;

            NEW.stored_at := now_utc;
            RETURN NEW;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS frequency_windows_guard ON frequency_windows;
          CREATE TRIGGER frequency_windows_guard BEFORE INSERT ON frequency_windows
            FOR EACH ROW EXECUTE FUNCTION guard_frequency_window_insert();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS frequency_windows_guard ON frequency_windows;
          DROP FUNCTION IF EXISTS guard_frequency_window_insert();
        END
        $do$
        """)
      end

      statement :check_frequency_window_commit do
        # Runs at COMMIT (a deferred constraint trigger), on the wall clock
        # then: a row whose transaction reaches its commit after F is
        # refused, and nothing is stored.
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION check_frequency_window_commit() RETURNS trigger AS $fn$
          BEGIN
            IF (clock_timestamp() AT TIME ZONE 'UTC' <= wallop_freq_fetch_deadline(NEW.freq_start))
               IS NOT TRUE THEN
              RAISE EXCEPTION 'a frequency window must commit by its fetch deadline';
            END IF;

            RETURN NULL;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS frequency_windows_commit_deadline ON frequency_windows;
          CREATE CONSTRAINT TRIGGER frequency_windows_commit_deadline
            AFTER INSERT ON frequency_windows
            DEFERRABLE INITIALLY DEFERRED
            FOR EACH ROW EXECUTE FUNCTION check_frequency_window_commit();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS frequency_windows_commit_deadline ON frequency_windows;
          DROP FUNCTION IF EXISTS check_frequency_window_commit();
        END
        $do$
        """)
      end

      statement :prevent_frequency_window_mutation do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION prevent_frequency_window_mutation() RETURNS trigger AS $fn$
          BEGIN
            RAISE EXCEPTION 'frequency windows are write-once';
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS frequency_windows_immutable ON frequency_windows;
          CREATE TRIGGER frequency_windows_immutable BEFORE UPDATE OR DELETE ON frequency_windows
            FOR EACH ROW EXECUTE FUNCTION prevent_frequency_window_mutation();
          DROP TRIGGER IF EXISTS frequency_windows_no_truncate ON frequency_windows;
          CREATE TRIGGER frequency_windows_no_truncate BEFORE TRUNCATE ON frequency_windows
            EXECUTE FUNCTION prevent_frequency_window_mutation();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS frequency_windows_immutable ON frequency_windows;
          DROP TRIGGER IF EXISTS frequency_windows_no_truncate ON frequency_windows;
          DROP FUNCTION IF EXISTS prevent_frequency_window_mutation();
        END
        $do$
        """)
      end
    end
  end

  actions do
    defaults([:read])

    create :store do
      accept([:freq_start, :value, :raw])

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
    attribute(:freq_start, :utc_datetime_usec, allow_nil?: false)
    attribute(:value, :string, allow_nil?: false)
    # The Elexon response body, byte for byte: not trimmed (Ash trims a
    # :string by default), so the stored bytes are exactly the ones received.
    attribute(:raw, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    # Set by the insert trigger from the database clock.
    attribute(:stored_at, :utc_datetime_usec, allow_nil?: true)
  end

  identities do
    # T's single window. Its unique index is what makes every draw of T use
    # the same value.
    identity(:one_per_start, [:freq_start], message: "a window is already stored for this start")
  end
end
