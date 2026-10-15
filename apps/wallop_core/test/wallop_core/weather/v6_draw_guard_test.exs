defmodule WallopCore.Weather.V6DrawGuardTest do
  @moduledoc """
  The database refuses what the observation-weather protocol forbids, and
  leaves draws without a lock schema (every forecast draw) alone.
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.{Schedule, Stations}

  @lock_sql """
  UPDATE draws SET status = $5, lock_schema_version = $6, entropy_composition = $7,
    drand_chain = $8, drand_round = $2, weather_time = $3, weather_station = $4
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

    refusal(@lock_sql, [
      Ecto.UUID.dump!(draw.id),
      round,
      DateTime.to_naive(wt),
      o[:station],
      o[:status],
      o[:schema],
      o[:tag],
      o[:chain]
    ])
  end

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
    test "put_v6_awaiting! stores a draw and a signed receipt the guards accept", %{
      draw: d,
      s: s
    } do
      v6 = put_v6_awaiting!(d, s.weather_time, s.round)

      assert v6.status == :awaiting_entropy
      assert {v6.lock_schema_version, v6.entropy_composition} == {"6", LandObs.tag()}
      assert v6.expected_result_at == s.expected_result_at

      receipt = Ash.load!(v6, :receipt, authorize?: false).receipt
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
      assert v6.expected_result_at == Quicknet.pub_time(round)
    end

    test "a receipt must carry the draw's schema and tag, and a locked_at in time", %{
      draw: d,
      s: s
    } do
      assert lock(d, s.weather_time, s.round) == nil

      ok_at = s.latest_lock_at
      late_at = DateTime.add(ok_at, 1, :microsecond)

      assert insert_receipt(d, late_at, %{}) ==
               "v6 signed locked_at is too late for this draw time"

      assert insert_receipt(d, ok_at, %{"schema_version" => "5"}) ==
               "a v6 lock receipt must carry its draw's schema and entropy_composition"

      assert insert_receipt(d, ok_at, %{"entropy_composition" => "drand-quicknet+openmeteo-v1"}) ==
               "a v6 lock receipt must carry its draw's schema and entropy_composition"

      assert insert_receipt(d, ok_at, %{
               "locked_at" => WallopCore.Time.to_rfc3339_usec(DateTime.add(ok_at, -1, :second))
             }) == "receipt locked_at must equal the signed locked_at"

      # Last, because a draw has one receipt.
      assert insert_receipt(d, ok_at, %{}) == nil
    end

    test "a forecast draw's receipt is not checked" do
      draw = create_draw(create_api_key())
      receipt = Ash.load!(draw, :receipt, authorize?: false).receipt
      assert Jason.decode!(receipt.payload_jcs)["schema_version"] != "6"
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

    test "an unknown pair raises rather than fall through" do
      for record <- [
            %{lock_schema_version: "6", entropy_composition: "other-v1", drand_round: 7},
            %{lock_schema_version: "7", entropy_composition: LandObs.tag(), drand_round: 7},
            %{lock_schema_version: "6", entropy_composition: LandObs.tag(), drand_round: nil}
          ] do
        assert_raise ArgumentError, fn -> ExpectedResultAt.calculate([record], [], %{}) end
      end
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

  # Inserts a lock receipt for `draw` whose column locked_at is `locked_at`
  # and whose payload is a v6 payload with `overrides` merged in. The
  # signature is not checked by the database, so it is a placeholder.
  defp insert_receipt(draw, locked_at, overrides) do
    payload =
      %{
        "schema_version" => "6",
        "entropy_composition" => LandObs.tag(),
        "locked_at" => WallopCore.Time.to_rfc3339_usec(locked_at)
      }
      |> Map.merge(overrides)
      |> Jason.encode!()

    refusal(
      """
      INSERT INTO operator_receipts (id, operator_id, draw_id, sequence, commitment_hash,
        entry_hash, locked_at, signing_key_id, payload_jcs, signature, inserted_at)
      VALUES ($1, $2, $3, $4, 'h', 'h', $5, 'k', $6, $7, $5)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(draw.operator_id),
        id(draw),
        draw.operator_sequence,
        DateTime.to_naive(locked_at),
        payload,
        :binary.copy(<<0>>, 64)
      ]
    )
  end
end
