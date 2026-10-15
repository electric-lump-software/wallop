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
    @tag :pending_task_11
    test "INV-1 (Ash lock) the lock action refuses a draw time whose latest lock has passed",
         %{draw: d, key: key} do
      for late <- missed_schedules() do
        assert {:error, _} =
                 d
                 |> Ash.Changeset.for_update(:lock, %{draw_at: late.draw_at}, actor: key)
                 |> Ash.update()

        assert_still_open(d)
      end
    end

    test "INV-1 (raw UPDATE) a late lock is refused; the same draw then locks in time",
         %{draw: d, s: s} do
      for late <- missed_schedules() do
        assert raw_lock(d, late.weather_time, late.round) == @too_late
        assert_still_open(d)
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

      for sql <- [
            "UPDATE draws SET status = 'open' WHERE id = $1",
            "UPDATE draws SET status = 'open', lock_schema_version = NULL, entropy_composition = NULL WHERE id = $1"
          ] do
        assert try_sql(sql, [dump(d.id)]) != nil, sql
      end
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
    {"weather_station", :backup_station},
    {"weather_time", :plus_hour},
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
  defp tamper(:backup_station, _), do: Stations.backup().id

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

  # ── INV-3 ─────────────────────────────────────────────────────────

  # Pinned here as well as in the fixtures, so regenerating a fixture can't
  # move them. The fixtures are byte copies of the published vectors as they
  # stood before any v6 work (see V5BuilderRegressionTest); the two
  # execution files were copied in for this suite.
  @fixtures_dir Path.expand("../../fixtures/v5_builder_regression", __DIR__)
  @pinned %{
    "lock-receipt-v5.json" => "36427205d9e43e3207bba207c628fbb8a1b292bd3572e62c33cd5d08fe7cf517",
    "cross-receipt-linkage-v5.json" =>
      "54713e34d3bc84f6f60d59d428b0981816641201cd537dba44faa43be877be52",
    "lock-receipt.json" => "8beb350be89858ab6307fb67f4917e824e9d36b87fb1be7f966f57b699b756bc",
    "cross-receipt-linkage.json" =>
      "3fbacc9e2aa7e80593edcec4b64c89c791b776a9e3371af5e34bc8cdd4138fa3",
    "execution-receipt-v4.json" =>
      "fb2f44863148f3de23ee15e712100ba89d52ce95f237f5ad04ea8dfba843483c",
    "execution-receipt-drand-only-v4.json" =>
      "7f230c28622bbbfe2a92c691bf276d106952d64c0a6a83b636bd66f1765d02fa"
  }

  defp fixture(name), do: @fixtures_dir |> Path.join(name) |> File.read!() |> Jason.decode!()
  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp as_schema_4(jcs),
    do: jcs |> Jason.decode!() |> Map.put("schema_version", "4") |> Jcs.encode()

  defp time!(nil), do: nil

  defp time!(str) do
    {:ok, t, 0} = DateTime.from_iso8601(str)
    t
  end

  defp lock_input(map) do
    %{
      operator_id: map["operator_id"],
      operator_slug: map["operator_slug"],
      sequence: map["sequence"],
      draw_id: map["draw_id"],
      commitment_hash: map["commitment_hash"],
      entry_hash: map["entry_hash"],
      locked_at: time!(map["locked_at"]),
      signing_key_id: map["signing_key_id"],
      winner_count: map["winner_count"],
      drand_chain: map["drand_chain"],
      drand_round: map["drand_round"],
      weather_station: map["weather_station"],
      weather_time: time!(map["weather_time"]),
      wallop_core_version: map["wallop_core_version"],
      fair_pick_version: map["fair_pick_version"]
    }
  end

  defp exec_input(map) do
    %{
      draw_id: map["draw_id"],
      operator_id: map["operator_id"],
      operator_slug: map["operator_slug"],
      sequence: map["sequence"],
      lock_receipt_hash: map["lock_receipt_hash"],
      entry_hash: map["entry_hash"],
      drand_chain: map["drand_chain"],
      drand_round: map["drand_round"],
      drand_randomness: map["drand_randomness"],
      drand_signature: map["drand_signature"],
      weather_station: map["weather_station"],
      weather_observation_time: time!(map["weather_observation_time"]),
      weather_value: map["weather_value"],
      weather_fallback_reason: map["weather_fallback_reason"],
      wallop_core_version: map["wallop_core_version"],
      fair_pick_version: map["fair_pick_version"],
      seed: map["seed"],
      results: map["results"],
      executed_at: time!(map["executed_at"]),
      signing_key_id: map["signing_key_id"]
    }
  end

  describe "INV-3 lock v5 / exec v4 bytes are unchanged against the pinned hashes" do
    test "INV-3 the fixtures still carry the pinned hashes" do
      for {name, hash} <- @pinned do
        v = fixture(name)
        assert (v["expected_payload_sha256"] || v["expected_lock_payload_sha256"]) == hash, name
      end
    end

    test "INV-3 lock v5 bytes" do
      for name <- ["lock-receipt-v5.json", "cross-receipt-linkage-v5.json"] do
        v = fixture(name)

        payload =
          Protocol.build_receipt_payload(lock_input(v["input"] || v["lock_receipt_input"]))

        assert sha256_hex(payload) == @pinned[name], name
        assert Jason.decode!(payload)["schema_version"] == "5"
      end
    end

    test "INV-3 lock schema 4 bytes (lock v5 output with schema_version 4)" do
      for name <- ["lock-receipt.json", "cross-receipt-linkage.json"] do
        v = fixture(name)

        payload =
          Protocol.build_receipt_payload(lock_input(v["input"] || v["lock_receipt_input"]))

        assert sha256_hex(as_schema_4(payload)) == @pinned[name], name
      end
    end

    test "INV-3 exec v4 bytes, with weather and drand-only" do
      for name <- ["execution-receipt-v4.json", "execution-receipt-drand-only-v4.json"] do
        payload = Protocol.build_execution_receipt_payload(exec_input(fixture(name)["input"]))
        assert sha256_hex(payload) == @pinned[name], name
        assert Jason.decode!(payload)["schema_version"] == "4"
      end
    end
  end

  # ── INV-4 ─────────────────────────────────────────────────────────

  describe "INV-4 forecast/v5 draws are untouched by every v6 trigger" do
    setup do
      ensure_infrastructure_key()
      %{fkey: create_api_key()}
    end

    test "INV-4 insert, lock and receipt, execution with weather: all as before", %{fkey: key} do
      draw = create_draw(key)
      assert draw.status == :awaiting_entropy
      assert {draw.lock_schema_version, draw.entropy_composition} == {nil, nil}

      locked = Ash.load!(draw, [:receipt, :expected_result_at], authorize?: false)
      assert Jason.decode!(locked.receipt.payload_jcs)["schema_version"] == "5"
      assert locked.expected_result_at == nil

      done = execute_draw(draw, test_seed(), key)
      assert done.status == :completed
      done = Ash.load!(done, [:execution_receipt], authorize?: false)
      assert Jason.decode!(done.execution_receipt.payload_jcs)["schema_version"] == "4"
    end

    test "INV-4 drand-only execution as before", %{fkey: key} do
      done =
        key
        |> create_draw()
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(authorize?: false)
        |> Ash.Changeset.for_update(:execute_drand_only, %{
          drand_randomness: test_drand_randomness(),
          drand_signature: "test-signature",
          drand_response: "{}",
          weather_fallback_reason: "unreachable"
        })
        |> Ash.update!(authorize?: false)
        |> Ash.load!([:execution_receipt], authorize?: false)

      assert done.status == :completed
      assert {done.lock_schema_version, done.entropy_composition} == {nil, nil}
      assert Jason.decode!(done.execution_receipt.payload_jcs)["schema_version"] == "4"
    end

    test "INV-4 expiry as before", %{fkey: key} do
      expired =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: key)
        |> Ash.create!()
        |> Ash.Changeset.for_update(:expire, %{})
        |> Ash.update!(authorize?: false)

      assert expired.status == :expired
    end

    test "INV-4 raw SQL on a (NULL, NULL) draw meets none of the v6 rules", %{fkey: key} do
      draw = create_draw(key)
      [late | _] = missed_schedules()

      # Insert: a copy already out of open, with a NULL pair.
      assert try_sql(
               """
               INSERT INTO draws (id, status, winner_count, entry_count, api_key_id, operator_id,
                 operator_sequence, stage_timestamps, inserted_at, updated_at)
               SELECT $2, 'awaiting_entropy', winner_count, entry_count, api_key_id, operator_id,
                 operator_sequence + 100000, stage_timestamps, inserted_at, updated_at
               FROM draws WHERE id = $1
               """,
               [dump(draw.id), dump(Ecto.UUID.generate())]
             ) == nil

      # Lock: a raw lock long after any v6 deadline, with no v6 fields checked.
      open = open_draw_with_entries(key)

      assert try_sql(
               "UPDATE draws SET status = 'awaiting_entropy', weather_time = $2, drand_round = 1, weather_station = 'anywhere' WHERE id = $1",
               [dump(open.id), DateTime.to_naive(late.weather_time)]
             ) == nil

      # Receipt: anything not schema 6 goes in, as before.
      assert try_sql(
               """
               INSERT INTO operator_receipts (id, operator_id, draw_id, sequence, commitment_hash,
                 entry_hash, locked_at, signing_key_id, payload_jcs, signature, inserted_at)
               VALUES ($1, $2, $3, $4, 'x', 'x', $5, 'k', $6, $7, $5)
               """,
               [
                 dump(Ecto.UUID.generate()),
                 dump(open.operator_id),
                 dump(open.id),
                 open.operator_sequence,
                 NaiveDateTime.utc_now(),
                 Jason.encode!(%{"schema_version" => "5", "drand_round" => 1}),
                 :binary.copy(<<0>>, 64)
               ]
             ) == nil

      # Completion: any executed_at, no observation, no pub(R) rule.
      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])

      assert try_sql(
               "UPDATE draws SET status = 'completed', executed_at = $2 WHERE id = $1",
               [dump(draw.id), DateTime.to_naive(late.weather_time)]
             ) == nil
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
    fair_pick_version: "0.2.1"
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
    fair_pick_version: "0.2.1",
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

    test "INV-5 (builders) the lock v5 / exec v4 builders refuse a v6 or unknown tag" do
      lock = %{@lock_input | weather_station: "middle-wallop"}
      exec = %{@exec_input | weather_station: "middle-wallop", weather_value: "102500"}

      for tag <- [LandObs.tag(), "drand-quicknet+metoffice-landobs-v2", ""] do
        assert_raise ArgumentError, ~r/entropy_composition/, fn ->
          Protocol.build_receipt_payload(%{lock | entropy_composition: tag})
        end

        assert_raise ArgumentError, ~r/entropy_composition/, fn ->
          Protocol.build_execution_receipt_payload(%{exec | entropy_composition: tag})
        end
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

    @tag :pending_task_10
    test "INV-5 (execution) a stored unknown pair is never executed", %{key: key, s: s} do
      for {schema, tag} <- [{"6", "drand-quicknet+metoffice-landobs-v2"}, {"6", nil}] do
        draw = open_draw_with_entries(key)
        store_with_pair!(draw, s, "pending_entropy", schema, tag)

        assert {:error, _} =
                 Ash.get!(Draw, draw.id, authorize?: false)
                 |> Ash.Changeset.for_update(:execute_v6, %{
                   drand_randomness: String.duplicate("a", 64),
                   drand_signature: "sig",
                   drand_response: "{}"
                 })
                 |> Ash.update(authorize?: false)

        assert Ash.get!(Draw, draw.id, authorize?: false).status == :pending_entropy
      end
    end
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

    test "INV-13 no lib code defers constraints or prepares a transaction" do
      files = Path.wildcard(Path.join(@umbrella_root, "apps/*/lib/**/*"))
      assert Enum.any?(files, &String.ends_with?(&1, ".ex"))

      hits =
        for path <- files,
            File.regular?(path),
            {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            line =~ ~r/set\s+constraints|prepare\s+transaction/i,
            do: "#{Path.relative_to(path, @umbrella_root)}:#{n}: #{String.trim(line)}"

      assert hits == []
    end
  end
end
