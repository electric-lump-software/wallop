defmodule WallopCore.Invariants.LockAndGuardTest do
  @moduledoc """
  Group A: the lock and the database guard (INV-1 to INV-6).

  Each test is named after the rule it pins, so a failure reads as the
  broken rule. See `WallopCore.Invariants.SuiteTest` for the suite's rules.
  """
  use WallopCore.InvariantCase, async: false
  use ExUnitProperties

  @moduletag :invariant

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.{Schedule, Stations}

  @too_late "v6 lock is too late for this draw time"
  @lock_only "a v6 draw leaves open only by locking"
  @non_open ~w(awaiting_entropy pending_entropy completed failed expired locked)

  setup do
    {operator, key} = create_v6_operator()
    %{draw: open_draw_with_entries(key), s: in_time_schedule(), key: key, operator: operator}
  end

  defp reload(draw), do: Ash.get!(Draw, draw.id, authorize?: false, load: [:receipt])

  defp assert_still_open(draw) do
    open = reload(draw)
    assert open.status == :open
    assert {open.lock_schema_version, open.entropy_composition} == {nil, nil}
    assert open.receipt == nil
  end

  # ── INV-1 ─────────────────────────────────────────────────────────

  describe "INV-1 a v6 draw can't leave open once the DB clock is past weather_time - 46m" do
    test "INV-1 (Ash lock) the lock action refuses a draw time whose latest lock has passed",
         %{draw: d, key: key, s: s} do
      for late <- missed_schedules() do
        assert {:error, %Ash.Error.Invalid{errors: [error | _]}} =
                 d
                 |> Ash.Changeset.for_update(:lock, %{draw_at: late.draw_at}, actor: key)
                 |> Ash.update()

        assert error.field == :draw_at

        assert Keyword.get(error.vars, :latest_lock_at) ==
                 DateTime.to_iso8601(DateTime.truncate(late.latest_lock_at, :second))

        assert_still_open(d)
      end

      # Positive control: an in-time draw time locks under v6.
      assert {:ok, locked} =
               d
               |> Ash.Changeset.for_update(:lock, %{draw_at: s.draw_at}, actor: key)
               |> Ash.update()

      assert {locked.lock_schema_version, locked.drand_round} == {"6", s.round}
    end

    test "INV-1 (raw UPDATE) no target status is reachable late; the same draw then locks in time",
         %{draw: d, s: s} do
      for late <- missed_schedules(), status <- @non_open do
        expected = if status == "awaiting_entropy", do: @too_late, else: @lock_only

        assert raw_lock(d, late.weather_time, late.round, status: status) == expected,
               "#{status} at #{late.weather_time}"

        assert_still_open(d)
      end

      # In time, only awaiting_entropy is a way out of open.
      for status <- @non_open -- ["awaiting_entropy"] do
        assert raw_lock(d, s.weather_time, s.round, status: status) == @lock_only, status
      end

      assert raw_lock(d, s.weather_time, s.round) == nil
    end

    test "INV-1 (raw INSERT) a draw can't be inserted already locked under v6", %{draw: d, s: s} do
      [late | _] = missed_schedules()
      {hash, canonical} = entry_hash(d)

      for sched <- [s, late] do
        assert try_sql(
                 """
                 INSERT INTO draws (id, status, winner_count, entry_count, api_key_id,
                   operator_id, operator_sequence, stage_timestamps, inserted_at, updated_at,
                   lock_schema_version, entropy_composition, drand_chain, drand_round,
                   weather_time, weather_station, entry_hash, entry_canonical)
                 SELECT $2, 'awaiting_entropy', winner_count, entry_count, api_key_id,
                   operator_id, operator_sequence + 100000, stage_timestamps, inserted_at,
                   updated_at, '6', $3, $4, $5, $6, $7, $8, $9
                 FROM draws WHERE id = $1
                 """,
                 [
                   dump(d.id),
                   dump(Ecto.UUID.generate()),
                   LandObs.tag(),
                   Quicknet.chain_hash(),
                   sched.round,
                   DateTime.to_naive(sched.weather_time),
                   Stations.primary().id,
                   hash,
                   canonical
                 ]
               ) ==
                 "lock_schema_version and entropy_composition are set only when a draw leaves open"
      end
    end

    test "INV-1 (receipt before lock) a receipt inserted first never opens a way out",
         %{draw: d, s: s} do
      {payload, cols} = valid_receipt(d, s)

      # A schema 6 receipt can't go in before the lock.
      assert insert_receipt(payload, cols) ==
               "a schema 6 lock receipt needs a draw locked under schema 6"

      # A non-6 receipt can, and then no v6 lock is accepted, late or in time.
      five = %{payload | "schema_version" => "5"}

      Repo.query!(
        """
        INSERT INTO operator_receipts (id, operator_id, draw_id, sequence, commitment_hash,
          entry_hash, locked_at, signing_key_id, payload_jcs, signature, inserted_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $7)
        """,
        [
          dump(Ecto.UUID.generate()),
          dump(cols.operator_id),
          dump(cols.draw_id),
          cols.sequence,
          cols.commitment_hash,
          cols.entry_hash,
          DateTime.to_naive(cols.locked_at),
          cols.signing_key_id,
          Jason.encode!(five),
          :binary.copy(<<0>>, 64)
        ]
      )

      for late <- missed_schedules() do
        assert raw_lock(d, late.weather_time, late.round) == @too_late
      end

      assert raw_lock(d, s.weather_time, s.round) ==
               "a v6 lock receipt must carry its draw's schema and entropy_composition"

      assert Ash.get!(Draw, d.id, authorize?: false).status == :open
    end

    test "INV-1 (receipt after lock) a receipt signed after the latest lock is refused",
         %{draw: d, s: s} do
      assert raw_lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      assert insert_receipt(payload, cols) == nil

      late = DateTime.add(s.latest_lock_at, 1, :microsecond)

      assert insert_receipt(%{payload | "locked_at" => rfc(late)}, %{cols | locked_at: late}) ==
               "v6 signed locked_at is too late for this draw time"
    end

    test "INV-1 (re-lock) a locked v6 draw can't go back to open", %{draw: d, s: s} do
      assert raw_lock(d, s.weather_time, s.round) == nil

      for {sql, message} <- [
            {"UPDATE draws SET status = 'open' WHERE id = $1",
             "lock_schema_version and entropy_composition are set only when a draw leaves open"},
            {"UPDATE draws SET status = 'open', lock_schema_version = NULL, entropy_composition = NULL WHERE id = $1",
             "lock_schema_version and entropy_composition are frozen once a draw has left open"}
          ] do
        assert try_sql(sql, [dump(d.id)]) == message, sql
      end

      # Positive control: the locked draw moves on as normal.
      assert try_sql("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(d.id)]) ==
               nil
    end
  end

  # ── INV-2 ─────────────────────────────────────────────────────────

  # Every signed lock v6 key with a row counterpart, and a value that differs
  # from the row's. Keys with no row counterpart are listed in @unbound.
  @payload_tampers [
    {"draw_id", :uuid},
    {"operator_id", :uuid},
    {"operator_slug", {:string, "someone-else"}},
    {"sequence", :plus_one},
    {"entry_hash", {:string, String.duplicate("ab", 32)}},
    {"commitment_hash", {:string, String.duplicate("ab", 32)}},
    {"winner_count", :plus_one},
    {"drand_chain", {:string, String.duplicate("0", 64)}},
    {"drand_round", :plus_one},
    {"weather_station", :wittering},
    {"weather_time", :plus_hour},
    {"freq_start", :plus_15s},
    {"signing_key_id", {:string, "deadbeef"}}
  ]

  @column_tampers [
    {:entry_hash, "entry_hash", {:string, String.duplicate("ab", 32)}},
    {:commitment_hash, "commitment_hash", {:string, String.duplicate("ab", 32)}},
    {:sequence, "sequence", :plus_one},
    {:signing_key_id, "signing_key_id", {:string, "deadbeef"}},
    {:operator_id, "operator_id", :other_operator}
  ]

  # Signed keys with no row counterpart: constants of the build.
  @unbound ~w(fair_pick_version jcs_version signature_algorithm wallop_core_version)

  defp tamper(:uuid, _), do: Ecto.UUID.generate()
  defp tamper({:string, value}, _), do: value
  defp tamper(:plus_one, value), do: value + 1
  defp tamper(:wittering, _), do: "wmo-03462"

  defp tamper(:plus_15s, value) do
    {:ok, t, 0} = DateTime.from_iso8601(value)
    rfc(DateTime.add(t, 15))
  end

  defp tamper(:plus_hour, value) do
    {:ok, t, 0} = DateTime.from_iso8601(value)
    rfc(DateTime.add(t, 3600))
  end

  defp tamper(:other_operator, _), do: create_operator().id

  describe "INV-2 every signed lock field with a row counterpart equals the row" do
    setup %{draw: d, s: s} do
      assert raw_lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      assert insert_receipt(payload, cols) == nil
      %{payload: payload, cols: cols}
    end

    test "INV-2 every signed key is either bound to the row or a build constant",
         %{payload: payload} do
      bound =
        Enum.map(@payload_tampers, &elem(&1, 0)) ++
          ~w(schema_version entropy_composition locked_at)

      assert Enum.sort(Map.keys(payload)) == Enum.sort(bound ++ @unbound)
      assert Enum.sort(Map.keys(payload)) == LandObs.lock_keys()
    end

    test "INV-2 signed schema_version and entropy_composition equal the draw's",
         %{payload: payload, cols: cols} do
      for {key, value} <- [
            {"schema_version", "5"},
            {"schema_version", nil},
            {"entropy_composition", "drand-quicknet+metoffice-landobs-v2"},
            {"entropy_composition", nil}
          ] do
        assert insert_receipt(Map.put(payload, key, value), cols) ==
                 "a v6 lock receipt must carry its draw's schema and entropy_composition",
               inspect({key, value})
      end
    end

    test "INV-2 signed locked_at equals the receipt's locked_at column",
         %{payload: payload, cols: cols} do
      assert insert_receipt(payload, %{cols | locked_at: DateTime.add(cols.locked_at, -1)}) ==
               "receipt locked_at must equal the signed locked_at"
    end

    for {key, how} <- @payload_tampers do
      @key key
      @how how
      test "INV-2 signed #{key} equals the row", %{payload: payload, cols: cols} do
        tampered = Map.put(payload, @key, tamper(@how, payload[@key]))

        assert insert_receipt(tampered, cols) ==
                 "v6 lock receipt field #{@key} does not match the draw"
      end
    end

    for {col, key, how} <- @column_tampers do
      @col col
      @key key
      @how how
      test "INV-2 receipt column #{col} equals the row", %{payload: payload, cols: cols} do
        tampered = Map.put(cols, @col, tamper(@how, Map.fetch!(cols, @col)))

        assert insert_receipt(payload, tampered) ==
                 "v6 lock receipt field #{@key} does not match the draw"
      end
    end
  end

  # ── The guard triggers ────────────────────────────────────────────

  # Every trigger on the tables the invariants rest on, as the database
  # defines it, enabled. A dropped, disabled or changed trigger fails here.
  @guard_triggers [
    "O CREATE TRIGGER draws_no_truncate BEFORE TRUNCATE ON public.draws FOR EACH STATEMENT EXECUTE FUNCTION prevent_draws_truncate()",
    "O CREATE CONSTRAINT TRIGGER draws_v6_completed_commit AFTER UPDATE ON public.draws DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (((new.status = 'completed'::text) AND (old.status IS DISTINCT FROM 'completed'::text) AND ((new.lock_schema_version IS NOT NULL) OR (new.entropy_composition IS NOT NULL)))) EXECUTE FUNCTION check_v6_draw_completed_commit()",
    "O CREATE CONSTRAINT TRIGGER draws_v6_failed_commit AFTER UPDATE ON public.draws DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (((new.status = 'failed'::text) AND (old.status IS DISTINCT FROM 'failed'::text) AND ((new.lock_schema_version IS NOT NULL) OR (new.entropy_composition IS NOT NULL)))) EXECUTE FUNCTION check_v6_draw_failed_commit()",
    "O CREATE TRIGGER draws_v6_guard BEFORE DELETE OR UPDATE ON public.draws FOR EACH ROW EXECUTE FUNCTION guard_v6_draw()",
    "O CREATE TRIGGER draws_v6_insert_guard BEFORE INSERT ON public.draws FOR EACH ROW EXECUTE FUNCTION guard_v6_draw_insert()",
    "O CREATE CONSTRAINT TRIGGER draws_v6_lock_commit AFTER UPDATE ON public.draws DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (((old.status = 'open'::text) AND (new.status IS DISTINCT FROM 'open'::text) AND ((new.lock_schema_version IS NOT NULL) OR (new.entropy_composition IS NOT NULL)))) EXECUTE FUNCTION check_v6_draw_lock_commit()",
    "O CREATE TRIGGER enforce_draw_immutability BEFORE DELETE OR UPDATE ON public.draws FOR EACH ROW EXECUTE FUNCTION prevent_draw_mutation()",
    "O CREATE TRIGGER execution_receipt_immutability BEFORE DELETE OR UPDATE ON public.execution_receipts FOR EACH ROW EXECUTE FUNCTION prevent_execution_receipt_mutation()",
    "O CREATE TRIGGER execution_receipts_no_truncate BEFORE TRUNCATE ON public.execution_receipts FOR EACH STATEMENT EXECUTE FUNCTION prevent_execution_receipts_truncate()",
    "O CREATE TRIGGER execution_receipts_v6_guard BEFORE INSERT ON public.execution_receipts FOR EACH ROW EXECUTE FUNCTION guard_v6_execution_receipt()",
    "O CREATE CONSTRAINT TRIGGER frequency_windows_commit_deadline AFTER INSERT ON public.frequency_windows DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_frequency_window_commit()",
    "O CREATE TRIGGER frequency_windows_guard BEFORE INSERT ON public.frequency_windows FOR EACH ROW EXECUTE FUNCTION guard_frequency_window_insert()",
    "O CREATE TRIGGER frequency_windows_immutable BEFORE DELETE OR UPDATE ON public.frequency_windows FOR EACH ROW EXECUTE FUNCTION prevent_frequency_window_mutation()",
    "O CREATE TRIGGER frequency_windows_no_truncate BEFORE TRUNCATE ON public.frequency_windows FOR EACH STATEMENT EXECUTE FUNCTION prevent_frequency_window_mutation()",
    "O CREATE TRIGGER operator_receipts_immutable BEFORE DELETE OR UPDATE ON public.operator_receipts FOR EACH ROW EXECUTE FUNCTION prevent_receipt_mutation()",
    "O CREATE TRIGGER operator_receipts_no_truncate BEFORE TRUNCATE ON public.operator_receipts FOR EACH STATEMENT EXECUTE FUNCTION prevent_operator_receipts_truncate()",
    "O CREATE TRIGGER operator_receipts_v6_guard BEFORE INSERT ON public.operator_receipts FOR EACH ROW EXECUTE FUNCTION guard_v6_lock_receipt()",
    "O CREATE CONSTRAINT TRIGGER weather_observations_commit_deadline AFTER INSERT ON public.weather_observations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_weather_observation_commit()",
    "O CREATE TRIGGER weather_observations_guard BEFORE INSERT ON public.weather_observations FOR EACH ROW EXECUTE FUNCTION guard_weather_observation_insert()",
    "O CREATE TRIGGER weather_observations_immutable BEFORE DELETE OR UPDATE ON public.weather_observations FOR EACH ROW EXECUTE FUNCTION prevent_weather_observation_mutation()",
    "O CREATE TRIGGER weather_observations_no_truncate BEFORE TRUNCATE ON public.weather_observations FOR EACH STATEMENT EXECUTE FUNCTION prevent_weather_observation_mutation()"
  ]

  describe "INV-1 the guard triggers are all in place" do
    test "INV-1 (trigger set) draws, receipts, observations and frequency windows carry exactly these triggers, enabled" do
      %{rows: rows} =
        Repo.query!("""
        SELECT tgenabled::text || ' ' || pg_get_triggerdef(oid) FROM pg_trigger
        WHERE NOT tgisinternal
          AND tgrelid::regclass::text IN
            ('draws', 'operator_receipts', 'execution_receipts', 'weather_observations',
             'frequency_windows')
        ORDER BY tgrelid::regclass::text, tgname
        """)

      assert List.flatten(rows) == @guard_triggers
    end
  end

  # ── INV-3 ─────────────────────────────────────────────────────────

  describe "INV-3 every lock is a lock schema 6 lock: an open draw with no lock schema can only expire" do
    setup do
      ensure_infrastructure_key()
      %{fkey: create_api_key()}
    end

    test "INV-3 an open draw with a NULL pair still expires", %{fkey: key} do
      expired =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: key)
        |> Ash.create!()
        |> Ash.Changeset.for_update(:expire, %{})
        |> Ash.update!(authorize?: false)

      assert expired.status == :expired
      assert {expired.lock_schema_version, expired.entropy_composition} == {nil, nil}
    end

    test "INV-3 an open draw can't leave open with a NULL pair except by expiring",
         %{fkey: key} do
      [late | _] = missed_schedules()

      for status <- ~w(locked awaiting_entropy pending_entropy completed failed) do
        open = open_draw_with_entries(key)

        assert try_sql(
                 "UPDATE draws SET status = $2, weather_time = $3, drand_round = 1, weather_station = 'anywhere' WHERE id = $1",
                 [dump(open.id), status, DateTime.to_naive(late.weather_time)]
               ) =~ "leaves open only by locking under lock schema 6",
               status

        assert Repo.reload!(open).status == :open
      end
    end
  end

  # ── INV-4 ─────────────────────────────────────────────────────────

  describe "INV-4 a retired forecast draw meets no v6 rule" do
    setup do
      ensure_infrastructure_key()
      %{fkey: create_api_key()}
    end

    test "INV-4 raw SQL on a retired (NULL, NULL) draw meets none of the v6 rules",
         %{fkey: key} do
      draw = put_retired_forecast_draw!(key, :awaiting_entropy)
      [late | _] = missed_schedules()

      # Insert: a copy already out of open, with a NULL pair, is refused:
      # it would be a lock with no lock schema.
      assert try_sql(
               """
               INSERT INTO draws (id, status, winner_count, entry_count, api_key_id, operator_id,
                 operator_sequence, stage_timestamps, inserted_at, updated_at)
               SELECT $2, 'awaiting_entropy', winner_count, entry_count, api_key_id, operator_id,
                 operator_sequence + 100000, stage_timestamps, inserted_at, updated_at
               FROM draws WHERE id = $1
               """,
               [dump(draw.id), dump(Ecto.UUID.generate())]
             ) == "a draw is created open"

      # Completion: any executed_at, no observation, no pub(R) rule.
      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])

      assert try_sql(
               "UPDATE draws SET status = 'completed', executed_at = $2 WHERE id = $1",
               [dump(draw.id), DateTime.to_naive(late.weather_time)]
             ) == nil

      # Execution receipt: anything not schema 5 goes in.
      for payload <- [Jason.encode!(%{"schema_version" => "4", "sequence" => 7.0}), "not json"] do
        assert insert_exec_receipt(payload, %{
                 draw_id: draw.id,
                 operator_id: draw.operator_id,
                 sequence: draw.operator_sequence,
                 lock_receipt_hash: "x",
                 signing_key_id: "k"
               }) == nil
      end

      # Failing long after its round published (round 1, in 2023), from
      # awaiting_entropy: allowed, so a stranded retired draw can be failed.
      stranded = put_retired_forecast_draw!(key, :awaiting_entropy)

      assert try_sql("UPDATE draws SET status = 'failed' WHERE id = $1", [dump(stranded.id)]) ==
               nil

      # Delete of a draw out of open, with no receipt.
      copy = Ecto.UUID.generate()

      with_triggers_off(fn ->
        Repo.query!(
          """
          INSERT INTO draws (id, status, winner_count, entry_count, api_key_id, operator_id,
            operator_sequence, stage_timestamps, inserted_at, updated_at)
          SELECT $2, 'pending_entropy', winner_count, entry_count, api_key_id, operator_id,
            operator_sequence + 200000, stage_timestamps, inserted_at, updated_at
          FROM draws WHERE id = $1
          """,
          [dump(draw.id), dump(copy)]
        )
      end)

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(copy)]) == nil
    end
  end

  # ── INV-5 ─────────────────────────────────────────────────────────

  @unknown_tags ["drand-quicknet+metoffice-landobs-v2", "drand-quicknet+openmeteo-v1", "", nil]

  # drand_round 33_068_212 publishes at 2026-10-14 20:00:00Z; its
  # observation hour is 19:00:00Z.
  @lock_input %{
    entropy_composition: "drand-quicknet+metoffice-landobs-v1",
    operator_id: "11111111-1111-1111-1111-111111111111",
    operator_slug: "acme-prizes",
    sequence: 7,
    draw_id: "22222222-2222-2222-2222-222222222222",
    commitment_hash: String.duplicate("ab", 32),
    entry_hash: String.duplicate("ab", 32),
    locked_at: ~U[2026-10-14 18:00:00.123456Z],
    signing_key_id: "deadbeef",
    winner_count: 2,
    drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
    drand_round: 33_068_212,
    weather_station: "wmo-03749",
    weather_time: ~U[2026-10-14 19:00:00.000000Z],
    wallop_core_version: "0.29.0",
    fair_pick_version: to_string(Application.spec(:fair_pick, :vsn))
  }

  @exec_input %{
    entropy_composition: "drand-quicknet+metoffice-landobs-v1",
    draw_id: "22222222-2222-2222-2222-222222222222",
    operator_id: "11111111-1111-1111-1111-111111111111",
    operator_slug: "acme-prizes",
    sequence: 7,
    lock_receipt_hash: String.duplicate("cd", 32),
    entry_hash: String.duplicate("ab", 32),
    drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
    drand_round: 33_068_212,
    drand_randomness: "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd",
    drand_signature: String.duplicate("ab", 48),
    weather_station: "wmo-03749",
    weather_observation_time: ~U[2026-10-14 19:00:00.000000Z],
    weather_value: "141;1025;85;2432",
    weather_fallback_reason: nil,
    wallop_core_version: "0.29.0",
    fair_pick_version: to_string(Application.spec(:fair_pick, :vsn)),
    seed: String.duplicate("ef", 32),
    results: ["33333333-3333-3333-3333-333333333333"],
    executed_at: ~U[2026-10-14 20:00:06.000000Z],
    signing_key_id: "cafebabe"
  }

  @unknown_pairs [
    {"6", "drand-quicknet+metoffice-landobs-v2"},
    {"6", nil},
    {"5", "drand-quicknet+metoffice-landobs-v1"},
    {"7", "drand-quicknet+metoffice-landobs-v1"},
    {nil, "drand-quicknet+metoffice-landobs-v1"}
  ]

  defp unknown_pair_message({schema, tag}),
    do:
      "unknown lock_schema_version and entropy_composition pair: " <>
        "(#{schema || "<NULL>"}, #{tag || "<NULL>"})"

  # Stores the draw as a v6 draw in `status` under `tag`, with every
  # trigger off, so the guards can be tried on a pair they would refuse.
  defp store_with_pair!(draw, s, status, schema, tag) do
    {hash, canonical} = entry_hash(draw)

    with_triggers_off(fn ->
      Repo.query!(
        """
        UPDATE draws SET status = $2, lock_schema_version = $3, entropy_composition = $4,
          drand_chain = $5, drand_round = $6, weather_time = $7, weather_station = $8,
          entry_hash = $9, entry_canonical = $10
        WHERE id = $1
        """,
        [
          dump(draw.id),
          status,
          schema,
          tag,
          Quicknet.chain_hash(),
          s.round,
          DateTime.to_naive(s.weather_time),
          Stations.primary().id,
          hash,
          canonical
        ]
      )
    end)
  end

  describe "INV-5 an unknown (schema, tag) pair is refused" do
    test "INV-5 (builders) the v6 builders raise on any other tag" do
      for tag <- @unknown_tags do
        assert_raise ArgumentError, ~r/entropy_composition/, fn ->
          Protocol.build_v6_lock_payload(%{@lock_input | entropy_composition: tag})
        end

        assert_raise ArgumentError, ~r/entropy_composition/, fn ->
          Protocol.build_v6_execution_payload(%{@exec_input | entropy_composition: tag})
        end
      end

      assert_raise ArgumentError, ~r/entropy_composition/, fn ->
        Protocol.build_v6_lock_payload(Map.delete(@lock_input, :entropy_composition))
      end
    end

    test "INV-5 (draws UPDATE trigger) leaving open under an unknown pair is refused",
         %{draw: d, s: s} do
      for {schema, tag} = pair <- @unknown_pairs do
        assert raw_lock(d, s.weather_time, s.round, schema: schema, tag: tag) ==
                 unknown_pair_message(pair),
               inspect(pair)
      end
    end

    test "INV-5 (draws INSERT trigger) a draw can't be inserted with any pair", %{draw: d} do
      for {schema, tag} = pair <- [{"6", LandObs.tag()} | @unknown_pairs] do
        assert try_sql(
                 """
                 INSERT INTO draws (id, status, winner_count, entry_count, api_key_id, operator_id,
                   operator_sequence, stage_timestamps, inserted_at, updated_at,
                   lock_schema_version, entropy_composition)
                 SELECT $2, 'open', winner_count, entry_count, api_key_id, operator_id,
                   operator_sequence + 100000, stage_timestamps, inserted_at, updated_at, $3, $4
                 FROM draws WHERE id = $1
                 """,
                 [dump(d.id), dump(Ecto.UUID.generate()), schema, tag]
               ) ==
                 "lock_schema_version and entropy_composition are set only when a draw leaves open",
               inspect(pair)
      end
    end

    test "INV-5 (draws UPDATE trigger) a stored unknown pair can't move on", %{draw: d, s: s} do
      store_with_pair!(d, s, "awaiting_entropy", "6", "drand-quicknet+metoffice-landobs-v2")
      message = unknown_pair_message({"6", "drand-quicknet+metoffice-landobs-v2"})

      assert try_sql("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(d.id)]) ==
               message

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(d.id)])
      end)

      assert try_sql(
               "UPDATE draws SET status = 'completed', executed_at = $2, weather_fallback_reason = $3 WHERE id = $1",
               [dump(d.id), NaiveDateTime.utc_now(), LandObs.fallback_reason()]
             ) == message
    end

    test "INV-5 (receipt trigger) a receipt under an unknown tag is refused", %{draw: d, s: s} do
      {payload, cols} = valid_receipt(d, s)
      other = "drand-quicknet+metoffice-landobs-v2"

      # On a draw without a pair: no schema 6 receipt at all.
      assert insert_receipt(%{payload | "entropy_composition" => other}, cols) ==
               "a schema 6 lock receipt needs a draw locked under schema 6"

      # On a Land Obs draw: the receipt's tag must be the draw's.
      assert raw_lock(d, s.weather_time, s.round) == nil

      assert insert_receipt(%{payload | "entropy_composition" => other}, cols) ==
               "a v6 lock receipt must carry its draw's schema and entropy_composition"
    end

    test "INV-5 (receipt trigger) a draw stored under an unknown pair takes no receipt",
         %{draw: d, s: s} do
      other = "drand-quicknet+metoffice-landobs-v2"
      store_with_pair!(d, s, "awaiting_entropy", "6", other)
      {payload, cols} = valid_receipt(d, s)

      assert insert_receipt(%{payload | "entropy_composition" => other}, cols) ==
               "no lock receipt rules for entropy_composition #{other}"
    end

    test "INV-5 (execution receipt trigger) a draw stored under an unknown pair takes no execution receipt" do
      x = completed_v6_receipt_input(:fallback)
      json = Protocol.build_v6_execution_payload(x.input)
      assert insert_exec_receipt(json, x.cols) == nil

      other = "drand-quicknet+metoffice-landobs-v2"

      for {schema, tag} <- [{"6", other}, {"6", nil}, {"5", LandObs.tag()}, {nil, LandObs.tag()}] do
        with_triggers_off(fn ->
          Repo.query!(
            "UPDATE draws SET lock_schema_version = $2, entropy_composition = $3 WHERE id = $1",
            [dump(x.draw.id), schema, tag]
          )
        end)

        assert insert_exec_receipt(json, x.cols) ==
                 "no execution receipt rules for (#{schema || "<NULL>"}, #{tag || "<NULL>"})",
               inspect({schema, tag})
      end
    end

    test "INV-5 (execution) a stored unknown pair is never executed", %{key: key} do
      ensure_infrastructure_key()

      # A round published a minute ago: pub(R) and F are both behind us, so
      # nothing but the pair can stop the execution.
      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -60))
      past = %{round: round, weather_time: Schedule.weather_time_for_round(round)}

      for {schema, tag} = pair <- [{"6", "drand-quicknet+metoffice-landobs-v2"}, {"6", nil}] do
        draw = open_draw_with_entries(key)
        store_with_pair!(draw, past, "pending_entropy", schema, tag)

        assert {:error, error} = execute_v6(draw)
        assert error_text(error) =~ unknown_pair_message(pair), inspect(pair)
        assert Ash.get!(Draw, draw.id, authorize?: false).status == :pending_entropy
      end

      # Positive control: the known pair, in the same timing, executes.
      known = put_v6_awaiting!(open_draw_with_entries(key), past.weather_time, round)
      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(known.id)])
      assert {:ok, done} = execute_v6(known)
      assert done.status == :completed
    end
  end

  defp execute_v6(draw) do
    Draw
    |> Ash.get!(draw.id, authorize?: false)
    |> Ash.Changeset.for_update(:execute_v6, %{
      drand_randomness: "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd",
      drand_signature:
        "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf",
      drand_response: "{}"
    })
    |> Ash.update(authorize?: false)
  end

  # ── INV-6 ─────────────────────────────────────────────────────────

  # WallopCore.Weather.SqlSchedulePropertyTest checks the same functions
  # under Asia/Kolkata (300 runs each, plus pinned boundaries). This extends
  # it to zones with fractional and daylight-saving offsets, and walks every
  # round across both of the UK's clock changes.
  @zones ["America/St_Johns", "Pacific/Chatham", "Europe/London"]

  defp sql_one(sql, params) do
    %{rows: [[value]]} = Repo.query!(sql, params)
    value
  end

  defp utc(naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  describe "INV-6 SQL timing equals Elixir under a non-UTC session" do
    for zone <- @zones do
      @zone zone
      property "INV-6 pub time, weather_time and lock_allowed equal Schedule's under #{zone}" do
        Repo.query!("SET LOCAL TIME ZONE '#{@zone}'")

        check all(
                round <- integer(1..90_000_000),
                offset_us <- integer(-7_200_000_000..7_200_000_000),
                max_runs: 100
              ) do
          %{rows: [[pub, wt]]} =
            Repo.query!(
              "SELECT wallop_quicknet_pub_time($1), wallop_landobs_weather_time($1)",
              [round]
            )

          assert utc(pub) == Schedule.pub_time(round)
          assert utc(wt) == Schedule.weather_time_for_round(round)

          expected_wt = Schedule.weather_time_for_round(round)
          at = DateTime.add(expected_wt, offset_us, :microsecond)

          assert sql_one("SELECT wallop_landobs_lock_allowed($1, $2)", [
                   DateTime.to_naive(at),
                   DateTime.to_naive(expected_wt)
                 ]) == Schedule.lock_allowed?(at, expected_wt)
        end
      end
    end

    test "INV-6 every round across the UK clock changes, in a Europe/London session" do
      Repo.query!("SET LOCAL TIME ZONE 'Europe/London'")

      for change <- [~U[2026-10-25 01:00:00Z], ~U[2027-03-28 01:00:00Z]] do
        first = Quicknet.round_at_or_after(DateTime.add(change, -2 * 3600))
        last = Quicknet.round_at_or_after(DateTime.add(change, 2 * 3600))

        %{rows: rows} =
          Repo.query!(
            """
            SELECT r, wallop_quicknet_pub_time(r), wallop_landobs_weather_time(r),
              wallop_landobs_lock_allowed(wallop_landobs_weather_time(r) - wallop_landobs_lock_offset(),
                                          wallop_landobs_weather_time(r)),
              wallop_landobs_lock_allowed(wallop_landobs_weather_time(r) - wallop_landobs_lock_offset()
                                            + interval '1 microsecond',
                                          wallop_landobs_weather_time(r))
            FROM generate_series($1::bigint, $2::bigint) r
            """,
            [first, last]
          )

        assert length(rows) == last - first + 1

        for [round, pub, wt, at_limit, after_limit] <- rows do
          assert utc(pub) == Schedule.pub_time(round), "round #{round}"
          assert utc(wt) == Schedule.weather_time_for_round(round), "round #{round}"
          assert {at_limit, after_limit} == {true, false}, "round #{round}"
        end
      end
    end
  end

  # ── INV-12, INV-13 ────────────────────────────────────────────────

  # A commit can be held back past drand only by a transaction that is
  # still open (bounded by the commit-time check) or by one that was
  # prepared and committed later. These pin that the second way is shut.
  @umbrella_root Path.expand("../../../../..", __DIR__)

  describe "INV-12 / INV-13 no commit can be deferred past drand" do
    test "INV-12 prepared transactions are disabled on the database" do
      assert %{rows: [["0"]]} = Repo.query!("SHOW max_prepared_transactions")
    end

    # Scans the shipped code: apps/*/lib and apps/*/priv. The test-support
    # helpers under test/ turn triggers off on purpose and aren't scanned.
    @risky ~r/set\s+constraints|prepare\s+transaction|session_replication_role|disable\s+trigger/i

    # Existing migration lines that legitimately match: {file, trimmed line}.
    @allowed MapSet.new([
               {"apps/wallop_core/priv/repo/migrations/20260408204500_sandbox_draw_separation.exs",
                "# for this one DELETE via session_replication_role = replica."},
               {"apps/wallop_core/priv/repo/migrations/20260408204500_sandbox_draw_separation.exs",
                "SET LOCAL session_replication_role = 'replica';"},
               {"apps/wallop_core/priv/repo/migrations/20260409000000_db_level_immutability_hardening.exs",
                "Operators with `session_replication_role = 'replica'` access can still"},
               {"apps/wallop_core/priv/repo/migrations/20260330214430_migrate_entries_data.exs",
                "execute \"ALTER TABLE entries DISABLE TRIGGER entries_immutability\""},
               {"apps/wallop_core/priv/repo/migrations/20260330214430_migrate_entries_data.exs",
                "execute \"ALTER TABLE draws DISABLE TRIGGER enforce_draw_immutability\""}
             ])

    test "INV-13 no shipped code defers constraints, prepares a transaction or turns triggers off" do
      files =
        Path.wildcard(Path.join(@umbrella_root, "apps/*/lib/**/*")) ++
          Path.wildcard(Path.join(@umbrella_root, "apps/*/priv/**/*"))

      assert Enum.any?(files, &String.ends_with?(&1, ".ex"))
      assert Enum.any?(files, &String.contains?(&1, "/priv/repo/migrations/"))

      hits =
        for path <- files,
            File.regular?(path),
            contents <- [File.read!(path)],
            String.valid?(contents),
            {line, n} <- contents |> String.split("\n") |> Enum.with_index(1),
            line =~ @risky,
            file <- [Path.relative_to(path, @umbrella_root)],
            not MapSet.member?(@allowed, {file, String.trim(line)}),
            do: "#{file}:#{n}: #{String.trim(line)}"

      assert hits == []
    end
  end
end
