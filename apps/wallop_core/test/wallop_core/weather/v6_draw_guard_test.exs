defmodule WallopCore.Weather.V6DrawGuardTest do
  @moduledoc """
  The database refuses what the observation-weather protocol forbids, and
  leaves draws without a lock schema (every forecast draw) alone.
  """
  use WallopCore.DataCase, async: false

  import ExUnit.CaptureLog

  import WallopCore.TestHelpers

  require Ash.Query

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Resources.{Draw, Operator, OperatorSigningKey}
  alias WallopCore.Weather.{Schedule, Stations}

  @lock_sql """
  UPDATE draws SET status = $5, lock_schema_version = $6, entropy_composition = $7,
    drand_chain = $8, drand_round = $2, weather_time = $3, weather_station = $4,
    entry_hash = $9, entry_canonical = $10
  WHERE id = $1
  """

  # The refusal's message, or nil when the statement succeeds. Runs in a
  # savepoint so a refusal leaves the test transaction usable.
  defp refusal(sql, params) do
    Repo.transaction(fn -> Repo.query!(sql, params) end)
    nil
  rescue
    e in Postgrex.Error -> e.postgres.message
  end

  defp lock(draw, wt, round, overrides \\ []) do
    o =
      Keyword.merge(
        [
          station: Stations.primary().id,
          status: "awaiting_entropy",
          schema: "6",
          tag: LandObs.tag(),
          chain: Quicknet.chain_hash()
        ],
        overrides
      )

    {hash, canonical} = entry_hash(draw)

    refusal(@lock_sql, [
      Ecto.UUID.dump!(draw.id),
      round,
      DateTime.to_naive(wt),
      o[:station],
      o[:status],
      o[:schema],
      o[:tag],
      o[:chain],
      hash,
      canonical
    ])
  end

  defp entry_hash(draw),
    do: Protocol.entry_hash({draw.id, WallopCore.Entries.load_for_draw(draw.id)})

  defp id(draw), do: Ecto.UUID.dump!(draw.id)

  setup do
    {_op, key} = create_v6_operator()
    {:ok, s} = Schedule.schedule(Schedule.default_draw_at(DateTime.utc_now()))
    %{draw: open_draw_with_entries(key), s: s, key: key}
  end

  describe "a v6 lock" do
    test "a consistent, in-time lock passes", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round) == nil
    end

    test "weather_time must follow from drand_round", %{draw: d, s: s} do
      assert lock(d, DateTime.add(s.weather_time, -3600), s.round) ==
               "v6 weather_time must follow from drand_round"
    end

    test "the station must be the tag's first", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round, station: Stations.backup().id) ==
               "v6 lock weather_station must be #{Stations.primary().id}"
    end

    test "the chain must be quicknet", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round, chain: String.duplicate("0", 64)) ==
               "v6 drand_chain must be the quicknet chain"
    end

    test "a late lock is refused on the DB clock", %{draw: d} do
      {:ok, past} =
        Schedule.schedule(Schedule.default_draw_at(DateTime.add(DateTime.utc_now(), -4 * 3600)))

      assert lock(d, past.weather_time, past.round) == "v6 lock is too late for this draw time"
    end

    test "applies whenever a v6 draw leaves open, not only to awaiting_entropy", %{
      draw: d,
      s: s
    } do
      for status <- ~w(pending_entropy completed expired locked) do
        assert lock(d, s.weather_time, s.round, status: status) ==
                 "a v6 draw leaves open only by locking",
               status
      end
    end
  end

  describe "the (lock_schema_version, entropy_composition) pair" do
    test "only (NULL, NULL) and (6, the Land Observations tag) are accepted", %{
      draw: d,
      s: s
    } do
      for {schema, tag} <- [
            {"6", "drand-quicknet+metoffice-landobs-v2"},
            {"6", nil},
            {"5", LandObs.tag()},
            {"5", nil},
            {nil, LandObs.tag()}
          ] do
        assert lock(d, s.weather_time, s.round, schema: schema, tag: tag) ==
                 "unknown lock_schema_version and entropy_composition pair: " <>
                   "(#{schema || "<NULL>"}, #{tag || "<NULL>"})",
               inspect({schema, tag})
      end
    end

    test "can't be set on an open draw", %{draw: d} do
      for column <- ~w(lock_schema_version entropy_composition) do
        assert refusal("UPDATE draws SET #{column} = 'x' WHERE id = $1", [id(d)]) ==
                 "lock_schema_version and entropy_composition are set only when a draw leaves open"
      end
    end

    test "is frozen once the draw has left open", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round) == nil

      for sql <- [
            "UPDATE draws SET lock_schema_version = NULL WHERE id = $1",
            "UPDATE draws SET entropy_composition = NULL WHERE id = $1",
            "UPDATE draws SET entropy_composition = 'drand-quicknet+metoffice-landobs-v2' WHERE id = $1"
          ] do
        assert refusal(sql, [id(d)]) ==
                 "lock_schema_version and entropy_composition are frozen once a draw has left open"
      end
    end

    test "a forecast draw that has left open can't become v6" do
      draw = create_draw(create_api_key())
      assert draw.status == :awaiting_entropy

      assert refusal(
               "UPDATE draws SET lock_schema_version = '6', entropy_composition = $2 WHERE id = $1",
               [id(draw), LandObs.tag()]
             ) ==
               "lock_schema_version and entropy_composition are frozen once a draw has left open"
    end
  end

  describe "forecast draws are untouched" do
    test "lock, execute and expire work as before, with a (NULL, NULL) pair" do
      ensure_infrastructure_key()
      key = create_api_key()

      draw = create_draw(key)
      assert {draw.lock_schema_version, draw.entropy_composition} == {nil, nil}

      completed = execute_draw(draw, test_seed(), key)
      assert completed.status == :completed

      reloaded = Ash.get!(Draw, completed.id, authorize?: false, load: [:expected_result_at])
      assert {reloaded.lock_schema_version, reloaded.entropy_composition} == {nil, nil}
      assert reloaded.expected_result_at == nil

      open =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: key)
        |> Ash.create!()

      expired =
        open |> Ash.Changeset.for_update(:expire, %{}) |> Ash.update!(authorize?: false)

      assert expired.status == :expired
    end

    test "raw updates to a forecast draw don't reach the v6 rules" do
      draw = create_draw(create_api_key())
      past = DateTime.to_naive(DateTime.add(DateTime.utc_now(), -4 * 3600))

      # A v6 lock this late would be refused; a forecast draw's state moves on.
      assert refusal("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [id(draw)]) ==
               nil

      assert refusal("UPDATE draws SET executed_at = $2 WHERE id = $1", [id(draw), past]) == nil
    end
  end

  describe "the v6 lock receipt" do
    test "a real signed receipt passes after a real lock", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round) == nil
      {hash, _} = entry_hash(d)
      receipt = insert_v6_lock_receipt!(d, hash, LandObs.tag(), s.round)

      payload = Jason.decode!(receipt.payload_jcs)
      assert payload["schema_version"] == "6"
      assert payload["entropy_composition"] == LandObs.tag()
      assert payload["weather_time"] == WallopCore.Time.to_rfc3339_usec(s.weather_time)
      assert DateTime.compare(receipt.locked_at, s.latest_lock_at) == :lt
    end

    test "put_v6_awaiting! may place weather_time away from the signed hour", %{draw: d} do
      wt = DateTime.add(DateTime.utc_now(), -10 * 60) |> DateTime.truncate(:second)
      round = Quicknet.round_at_or_after(DateTime.add(wt, 30 * 60))
      v6 = put_v6_awaiting!(d, wt, round)

      assert DateTime.compare(v6.weather_time, wt) == :eq
      assert {v6.lock_schema_version, v6.entropy_composition} == {"6", LandObs.tag()}
      assert v6.expected_result_at == Quicknet.pub_time(round)

      payload = Jason.decode!(Ash.load!(v6, :receipt, authorize?: false).receipt.payload_jcs)

      assert payload["weather_time"] ==
               WallopCore.Time.to_rfc3339_usec(Schedule.weather_time_for_round(round))
    end

    test "the crafted valid receipt passes, so the refusals below are about one field", %{
      draw: d,
      s: s
    } do
      assert lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      assert insert_receipt(payload, cols) == nil
    end

    test "the signed locked_at must be in time and equal the column", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      late = DateTime.add(s.latest_lock_at, 1, :microsecond)

      assert insert_receipt(%{payload | "locked_at" => rfc(late)}, %{cols | locked_at: late}) ==
               "v6 signed locked_at is too late for this draw time"

      assert insert_receipt(payload, %{cols | locked_at: DateTime.add(cols.locked_at, -1)}) ==
               "receipt locked_at must equal the signed locked_at"
    end

    test "schema and tag must match the draw's", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)

      for {key, value} <- [
            {"schema_version", "5"},
            {"schema_version", nil},
            {"entropy_composition", "drand-quicknet+openmeteo-v1"},
            {"entropy_composition", nil}
          ] do
        assert insert_receipt(Map.put(payload, key, value), cols) ==
                 "a v6 lock receipt must carry its draw's schema and entropy_composition",
               inspect({key, value})
      end
    end

    test "every signed field with a row counterpart is bound to it", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      other_hash = String.duplicate("ab", 32)

      payload_cases = [
        {"draw_id", Ecto.UUID.generate()},
        {"operator_id", Ecto.UUID.generate()},
        {"operator_slug", "someone-else"},
        {"sequence", payload["sequence"] + 1},
        {"entry_hash", other_hash},
        {"commitment_hash", other_hash},
        {"winner_count", payload["winner_count"] + 1},
        {"drand_chain", String.duplicate("0", 64)},
        {"drand_round", payload["drand_round"] + 1},
        {"weather_station", Stations.backup().id},
        {"weather_time", rfc(DateTime.add(s.weather_time, 3600))},
        {"signing_key_id", "deadbeef"}
      ]

      for {key, value} <- payload_cases do
        assert insert_receipt(Map.put(payload, key, value), cols) ==
                 "v6 lock receipt field #{key} does not match the draw",
               key
      end

      column_cases = [
        {:entry_hash, "entry_hash", other_hash},
        {:commitment_hash, "commitment_hash", other_hash},
        {:sequence, "sequence", cols.sequence + 1},
        {:signing_key_id, "signing_key_id", "deadbeef"}
      ]

      for {col, key, value} <- column_cases do
        assert insert_receipt(payload, Map.put(cols, col, value)) ==
                 "v6 lock receipt field #{key} does not match the draw",
               "column #{col}"
      end
    end

    test "a signing key of another operator is refused", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      other = key_for(create_operator())

      assert insert_receipt(%{payload | "signing_key_id" => other.key_id}, %{
               cols
               | signing_key_id: other.key_id
             }) == "v6 lock receipt field signing_key_id does not match the draw"
    end

    test "the signing key must have been valid at the signed locked_at", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      locked_at = cols.locked_at

      # Entered the keyring after locked_at.
      later = add_key(d.operator_id, DateTime.add(locked_at, 600), DateTime.add(locked_at, 600))
      # Eligible (valid_from) before locked_at, but in the keyring only after:
      # the verifier's inserted_at <= locked_at rule refuses it.
      straddling =
        add_key(d.operator_id, DateTime.add(locked_at, -30), DateTime.add(locked_at, 20))

      for key_id <- [later, straddling] do
        assert insert_receipt(%{payload | "signing_key_id" => key_id}, %{
                 cols
                 | signing_key_id: key_id
               }) == "v6 lock receipt signing key was not valid at locked_at"
      end
    end

    test "signed times must be canonical UTC strings", %{draw: d, s: s} do
      assert lock(d, s.weather_time, s.round) == nil
      {payload, cols} = valid_receipt(d, s)
      offset = Calendar.strftime(s.weather_time, "%Y-%m-%dT%H:%M:%S.000000+00:00")

      assert insert_receipt(%{payload | "weather_time" => offset}, cols) ==
               "not a canonical UTC timestamp: #{offset}"
    end
  end

  describe "the receipt guard fails closed" do
    test "a schema 6 receipt on a draw without a lock schema is refused", %{draw: d, s: s} do
      {payload, cols} = valid_receipt(d, s)

      assert insert_receipt(payload, cols) ==
               "a schema 6 lock receipt needs a draw locked under schema 6"
    end

    test "a non-6 receipt on a draw without a lock schema is untouched", %{draw: d, s: s} do
      {payload, cols} = valid_receipt(d, s)
      # Anything goes here, as before: the guard does not look past the schema.
      assert insert_receipt(%{payload | "schema_version" => "5", "drand_round" => 1}, cols) ==
               nil
    end

    test "a receipt inserted before the lock gets the same checks at the lock", %{
      draw: d,
      s: s
    } do
      {payload, cols} = valid_receipt(d, s)
      assert insert_receipt(%{payload | "schema_version" => "5"}, cols) == nil

      assert lock(d, s.weather_time, s.round) ==
               "a v6 lock receipt must carry its draw's schema and entropy_composition"
    end

    test "a forecast lock and its receipt work as before" do
      draw = create_draw(create_api_key())
      receipt = Ash.load!(draw, :receipt, authorize?: false).receipt
      assert Jason.decode!(receipt.payload_jcs)["schema_version"] != "6"
    end
  end

  describe "inserting a draw" do
    @copy_sql """
    INSERT INTO draws (id, status, winner_count, entry_count, api_key_id, operator_id,
      operator_sequence, stage_timestamps, inserted_at, updated_at,
      lock_schema_version, entropy_composition)
    SELECT $2, $3, winner_count, entry_count, api_key_id, operator_id,
      operator_sequence + 100000, stage_timestamps, inserted_at, updated_at, $4, $5
    FROM draws WHERE id = $1
    """

    defp copy(draw, status, schema, tag),
      do:
        refusal(@copy_sql, [
          id(draw),
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          status,
          schema,
          tag
        ])

    test "a draw without a lock schema inserts as before", %{draw: d} do
      assert copy(d, "open", nil, nil) == nil
    end

    test "a draw can't be inserted with a lock schema or tag", %{draw: d} do
      for {status, schema, tag} <- [
            {"open", "6", LandObs.tag()},
            {"awaiting_entropy", "6", LandObs.tag()},
            {"open", "6", nil},
            {"open", nil, LandObs.tag()}
          ] do
        assert copy(d, status, schema, tag) ==
                 "lock_schema_version and entropy_composition are set only when a draw leaves open",
               inspect({status, schema, tag})
      end
    end
  end

  describe "v6 completion" do
    # The stored-observation clauses read weather_observations, which a later
    # migration creates; they are tested with it. This clause runs first.
    test "can't complete before the drand round publishes", %{draw: d, s: s} do
      v6 = put_v6_awaiting!(d, s.weather_time, s.round)
      assert refusal("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [id(v6)]) == nil

      now = DateTime.to_naive(DateTime.utc_now())

      for executed_at <- [nil, now] do
        assert refusal(
                 "UPDATE draws SET status = 'completed', executed_at = $2 WHERE id = $1",
                 [id(v6), executed_at]
               ) == "v6 draw cannot complete before its drand round publishes"
      end
    end
  end

  describe "expected_result_at dispatch" do
    alias WallopCore.Resources.Draw.Calculations.ExpectedResultAt

    test "nil without a lock schema; pub(R) for (6, Land Observations)" do
      assert ExpectedResultAt.calculate(
               [
                 %{lock_schema_version: nil, entropy_composition: nil, drand_round: 7},
                 %{lock_schema_version: "6", entropy_composition: LandObs.tag(), drand_round: 7}
               ],
               [],
               %{}
             ) == [nil, Quicknet.pub_time(7)]
    end

    test "an inconsistent row gives nil and a warning naming only the redacted id" do
      draw_id = Ecto.UUID.generate()

      for record <- [
            %{lock_schema_version: "6", entropy_composition: "other-v1", drand_round: 7},
            %{lock_schema_version: "7", entropy_composition: LandObs.tag(), drand_round: 7},
            %{lock_schema_version: "6", entropy_composition: LandObs.tag(), drand_round: nil},
            %{lock_schema_version: nil, entropy_composition: LandObs.tag(), drand_round: 7}
          ] do
        log =
          capture_log(fn ->
            assert ExpectedResultAt.calculate([Map.put(record, :id, draw_id)], [], %{}) == [nil]
          end)

        assert log =~ "inconsistent lock schema on draw #{WallopCore.Log.redact_id(draw_id)}"
        refute log =~ draw_id
      end
    end

    test "an inconsistent stored row reads as nil, not an error", %{draw: d} do
      Repo.query!("SET session_replication_role = replica")

      try do
        Repo.query!(
          "UPDATE draws SET lock_schema_version = '6', entropy_composition = 'other-v1' WHERE id = $1",
          [id(d)]
        )
      after
        Repo.query!("RESET session_replication_role")
      end

      capture_log(fn ->
        assert Ash.get!(Draw, d.id, authorize?: false, load: [:expected_result_at]).expected_result_at ==
                 nil
      end)
    end
  end

  test "expected_result_at is pub(drand_round) for v6 draws and nil otherwise", %{
    draw: d,
    s: s
  } do
    assert lock(d, s.weather_time, s.round) == nil
    v6 = Ash.get!(Draw, d.id, authorize?: false, load: [:expected_result_at])
    assert v6.expected_result_at == s.expected_result_at

    v5 = Ash.load!(create_draw(create_api_key()), :expected_result_at, authorize?: false)
    assert v5.expected_result_at == nil
  end

  defp rfc(dt), do: WallopCore.Time.to_rfc3339_usec(dt)

  # A raw keyring row for the operator, with the given valid_from and
  # inserted_at (the keyring CHECK keeps them within 60 seconds).
  defp add_key(operator_id, valid_from, inserted_at) do
    {public_key, _private} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = Protocol.key_id(public_key)

    Repo.query!(
      """
      INSERT INTO operator_signing_keys (id, operator_id, key_id, public_key, private_key,
        valid_from, inserted_at)
      VALUES ($1, $2, $3, $4, 'unused', $5, $6)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(operator_id),
        key_id,
        public_key,
        DateTime.to_naive(valid_from),
        DateTime.to_naive(inserted_at)
      ]
    )

    key_id
  end

  defp key_for(operator) do
    operator_id = operator.id

    OperatorSigningKey
    |> Ash.Query.filter(operator_id == ^operator_id)
    |> Ash.read_one!(authorize?: false)
  end

  # A payload and receipt columns that pass the guards for `draw` locked by
  # lock(draw, s.weather_time, s.round), built by the real lock v6 builder.
  defp valid_receipt(draw, s) do
    operator = Ash.get!(Operator, draw.operator_id, authorize?: false)
    key = key_for(operator)
    {hash, _} = entry_hash(draw)
    # Now, after the operator's key entered the keyring, and in time for s.
    locked_at = DateTime.utc_now()

    payload =
      %{
        entropy_composition: LandObs.tag(),
        operator_id: operator.id,
        operator_slug: to_string(operator.slug),
        sequence: draw.operator_sequence,
        draw_id: draw.id,
        commitment_hash: hash,
        entry_hash: hash,
        locked_at: locked_at,
        signing_key_id: key.key_id,
        winner_count: draw.winner_count,
        drand_chain: Quicknet.chain_hash(),
        drand_round: s.round,
        weather_station: Stations.primary().id,
        weather_time: s.weather_time,
        wallop_core_version: "0.0.0",
        fair_pick_version: to_string(Application.spec(:fair_pick, :vsn))
      }
      |> Protocol.build_v6_lock_payload()
      |> Jason.decode!()

    cols = %{
      operator_id: operator.id,
      sequence: draw.operator_sequence,
      commitment_hash: hash,
      entry_hash: hash,
      locked_at: locked_at,
      signing_key_id: key.key_id,
      draw_id: draw.id
    }

    {payload, cols}
  end

  # Inserts a receipt row as given. The database does not check the
  # signature, so it is a placeholder.
  defp insert_receipt(payload, cols) do
    refusal(
      """
      INSERT INTO operator_receipts (id, operator_id, draw_id, sequence, commitment_hash,
        entry_hash, locked_at, signing_key_id, payload_jcs, signature, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $7)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(cols.operator_id),
        Ecto.UUID.dump!(cols.draw_id),
        cols.sequence,
        cols.commitment_hash,
        cols.entry_hash,
        DateTime.to_naive(cols.locked_at),
        cols.signing_key_id,
        Jason.encode!(payload),
        :binary.copy(<<0>>, 64)
      ]
    )
  end
end
