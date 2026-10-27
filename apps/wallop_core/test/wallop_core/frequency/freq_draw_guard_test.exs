defmodule WallopCore.Frequency.FreqDrawGuardTest do
  @moduledoc """
  The database refuses what the grid-frequency tag forbids, through the
  real squashed guards, and still leaves (NULL, NULL) draws alone.
  """
  use WallopCore.InvariantCase, async: false

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Protocol.Tags.Freq
  alias WallopCore.Resources.Draw

  setup do
    {_op, key} = create_freq_operator()
    %{draw: open_draw_with_entries(key), s: in_time_freq_schedule(), key: key}
  end

  describe "a frequency lock" do
    test "a consistent, in-time lock passes", %{draw: d, s: s} do
      assert raw_freq_lock(d, s) == nil
    end

    test "freq_start must follow from drand_round", %{draw: d, s: s} do
      assert raw_freq_lock(d, s, freq_start: DateTime.add(s.freq_start, -15)) ==
               "freq_start must follow from drand_round"

      assert raw_freq_lock(d, s, freq_start: nil) == "freq_start must follow from drand_round"
    end

    test "it carries no weather fields", %{draw: d, s: s} do
      assert raw_freq_lock(d, s, station: "wmo-03749") ==
               "a grid-frequency draw carries no weather fields"

      assert raw_freq_lock(d, s, weather_time: DateTime.add(s.freq_start, -3600)) ==
               "a grid-frequency draw carries no weather fields"
    end

    test "the chain must be quicknet", %{draw: d, s: s} do
      assert raw_freq_lock(d, s, chain: String.duplicate("0", 64)) ==
               "v6 drand_chain must be the quicknet chain"
    end

    test "a late lock is refused on the DB clock, after any row-lock wait", %{draw: d} do
      {:ok, past} =
        FreqSchedule.schedule(
          FreqSchedule.default_draw_at(DateTime.add(DateTime.utc_now(), -3600))
        )

      assert raw_freq_lock(d, past) == "v6 lock is too late for this draw time"

      %{rows: [[src]]} = Repo.query!("SELECT prosrc FROM pg_proc WHERE proname = 'guard_v6_draw'")

      assert src =~
               "wallop_freq_lock_allowed(clock_timestamp() AT TIME ZONE 'UTC', NEW.freq_start)"

      refute src =~ "wallop_freq_lock_allowed(now_utc"
    end

    test "an unknown tag, or the frequency tag on another schema, is refused", %{draw: d, s: s} do
      for {schema, tag} <- [
            {"6", "drand-quicknet+elexon-freq-v2"},
            {"5", Freq.tag()},
            {nil, Freq.tag()}
          ] do
        assert raw_freq_lock(d, s, schema: schema, tag: tag) ==
                 "unknown lock_schema_version and entropy_composition pair: " <>
                   "(#{schema || "<NULL>"}, #{tag || "<NULL>"})"
      end
    end
  end

  describe "the frequency columns" do
    test "can't be set on an open or forecast draw, are frozen after lock, and results wait for completion",
         %{draw: d, s: s} do
      assert try_sql("UPDATE draws SET freq_start = $2 WHERE id = $1", [
               dump(d.id),
               DateTime.to_naive(s.freq_start)
             ]) ==
               "frequency fields are set only on lock schema 6 draws"

      assert raw_freq_lock(d, s) == nil

      assert try_sql(
               "UPDATE draws SET freq_start = freq_start - interval '15 seconds' WHERE id = $1",
               [dump(d.id)]
             ) ==
               "freq_start is frozen once a draw has left open"

      assert try_sql("UPDATE draws SET freq_value = $2 WHERE id = $1", [
               dump(d.id),
               "50012;50018;50012;49983;49980;49953;49912;49883"
             ]) == "frequency results are set only when a draw completes"
    end

    test "a Land Observations draw carries freq_start, frozen once locked, and no results before completion" do
      {_op, key} = create_v6_operator()
      d = open_draw_with_entries(key)
      ws = in_time_schedule()
      assert raw_lock(d, ws.weather_time, ws.round) == nil

      assert try_sql(
               "UPDATE draws SET freq_start = freq_start + interval '15 seconds' WHERE id = $1",
               [dump(d.id)]
             ) ==
               "freq_start is frozen once a draw has left open"

      assert try_sql("UPDATE draws SET freq_value = $2 WHERE id = $1", [
               dump(d.id),
               "50012;50018;50012;49983;49980;49953;49912;49883"
             ]) == "frequency results are set only when a draw completes"
    end

    test "a draw can't be inserted with them", %{draw: d} do
      for {col, value, cast} <- [
            {"freq_start", ~N[2026-10-14 19:54:00], "timestamp"},
            {"freq_value", "x", "text"},
            {"freq_fallback_reason", "x", "text"}
          ] do
        assert try_sql(
                 """
                 INSERT INTO draws (id, status, winner_count, entry_count, api_key_id, operator_id,
                   operator_sequence, stage_timestamps, inserted_at, updated_at, #{col})
                 SELECT $2, 'open', winner_count, entry_count, api_key_id, operator_id,
                   operator_sequence + 100000, stage_timestamps, inserted_at, updated_at, $3::#{cast}
                 FROM draws WHERE id = $1
                 """,
                 [dump(d.id), dump(Ecto.UUID.generate()), value]
               ) == "frequency fields are set only on lock schema 6 draws",
               col
      end
    end

    test "a frequency draw in its lock window can't complete by the fallback", %{draw: d, s: s} do
      assert raw_freq_lock(d, s) == nil

      assert try_sql("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(d.id)]) ==
               nil

      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(d.id)])

      assert try_sql(
               "UPDATE draws SET status = 'completed', executed_at = $2, freq_fallback_reason = $3 WHERE id = $1",
               [
                 dump(d.id),
                 DateTime.to_naive(DateTime.add(Quicknet.pub_time(s.round), 1)),
                 Freq.fallback_reason()
               ]
             ) == "v6 draw may fall back only after the fetch deadline with nothing stored"
    end
  end

  describe "the weather columns on a frequency draw" do
    @weather_columns [
      {"weather_station", "wmo-03749", "text"},
      {"weather_time", ~N[2026-10-14 19:00:00], "timestamp"},
      {"weather_value", "12;1013;80;25000", "text"},
      {"weather_observation_time", ~N[2026-10-14 19:00:00], "timestamp"},
      {"weather_fallback_reason", "no_observation_by_deadline", "text"}
    ]

    @no_weather "a grid-frequency draw carries no weather fields"

    test "each is refused at lock", %{draw: d, s: s} do
      {hash, canonical} = entry_hash(d)

      for {col, value, cast} <- @weather_columns do
        assert try_sql(
                 """
                 UPDATE draws SET status = 'awaiting_entropy', lock_schema_version = '6',
                   entropy_composition = $2, drand_chain = $3, drand_round = $4, freq_start = $5,
                   entry_hash = $6, entry_canonical = $7, #{col} = $8::#{cast}
                 WHERE id = $1
                 """,
                 [
                   dump(d.id),
                   Freq.tag(),
                   Quicknet.chain_hash(),
                   s.round,
                   DateTime.to_naive(s.freq_start),
                   hash,
                   canonical,
                   value
                 ]
               ) == @no_weather,
               col
      end

      assert raw_freq_lock(d, s) == nil
    end

    test "each is refused after lock, at every later status", %{draw: d, s: s} do
      assert raw_freq_lock(d, s) == nil

      for status <- ~w(awaiting_entropy pending_entropy) do
        assert try_sql("UPDATE draws SET status = $2 WHERE id = $1", [dump(d.id), status]) == nil
        Repo.query!("UPDATE draws SET status = $2 WHERE id = $1", [dump(d.id), status])

        for {col, value, cast} <- @weather_columns do
          assert try_sql("UPDATE draws SET #{col} = $2::#{cast} WHERE id = $1", [
                   dump(d.id),
                   value
                 ]) ==
                   @no_weather,
                 "#{col} at #{status}"
        end
      end
    end
  end

  describe "failing a frequency draw (the failed rule by tag)" do
    test "is refused once its F has passed, and allowed before F" do
      {_op, key} = create_freq_operator()
      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3600))

      past_f =
        DateTime.utc_now()
        |> DateTime.add(-(FreqSchedule.span_seconds() + FreqSchedule.fetch_window_seconds() + 5))
        |> DateTime.truncate(:second)

      late = put_freq_awaiting!(open_draw_with_entries(key), past_f, round)

      assert try_sql("UPDATE draws SET status = 'failed', failed_at = $2 WHERE id = $1", [
               dump(late.id),
               NaiveDateTime.utc_now()
             ]) ==
               "a v6 draw can't fail once its fetch deadline has passed"

      early = put_freq_awaiting!(open_draw_with_entries(key), aligned_freq_start(60), round)

      assert try_sql("UPDATE draws SET status = 'failed', failed_at = $2 WHERE id = $1", [
               dump(early.id),
               NaiveDateTime.utc_now()
             ]) == nil
    end

    test "the commit-time twin reads F by tag too" do
      %{rows: [[src]]} =
        Repo.query!("SELECT prosrc FROM pg_proc WHERE proname = 'check_v6_draw_failed_commit'")

      assert src =~
               "wallop_v6_fetch_deadline(NEW.entropy_composition, NEW.weather_time, NEW.freq_start)"
    end
  end

  describe "retired forecast draws return before any tag arm" do
    test "a (NULL, NULL) draw meets no tag rule, but can't carry the frequency columns" do
      draw = put_retired_forecast_draw!(create_api_key(), :awaiting_entropy)
      assert {draw.lock_schema_version, draw.entropy_composition} == {nil, nil}

      assert try_sql("UPDATE draws SET freq_value = 'x' WHERE id = $1", [dump(draw.id)]) ==
               "frequency fields are set only on lock schema 6 draws"

      %{rows: [[src]]} = Repo.query!("SELECT prosrc FROM pg_proc WHERE proname = 'guard_v6_draw'")
      [early, _rest] = String.split(src, "RETURN NEW;", parts: 2)
      refute early =~ "wallop_landobs_tag()"
      refute early =~ "wallop_freq_tag()"
    end
  end

  describe "the frequency lock receipt" do
    test "the real builder's receipt passes after a real lock", %{draw: d, s: s} do
      {payload, cols} = valid_freq_receipt(d, s)
      assert raw_freq_lock(d, s) == nil
      assert insert_receipt(payload, cols) == nil
    end

    test "every frequency-bound field is checked, receipt after the lock", %{draw: d, s: s} do
      {payload, cols} = valid_freq_receipt(d, s)
      assert raw_freq_lock(d, s) == nil

      assert insert_receipt(
               %{payload | "freq_start" => rfc(DateTime.add(s.freq_start, 15))},
               cols
             ) ==
               "v6 lock receipt field freq_start does not match the draw"

      assert insert_receipt(%{payload | "weather_station" => "wmo-03749"}, cols) ==
               "v6 lock receipt field weather_station does not match the draw"

      assert insert_receipt(Map.delete(payload, "freq_start"), cols) ==
               "v6 lock receipt keys are not the tag's key set"

      late = DateTime.add(FreqSchedule.latest_lock_at(s.freq_start), 1, :microsecond)

      assert insert_receipt(%{payload | "locked_at" => rfc(late)}, %{cols | locked_at: late}) ==
               "v6 signed locked_at is too late for this draw time"
    end

    test "a receipt inserted before the lock gets the same checks at the lock", %{draw: d, s: s} do
      {payload, cols} = valid_freq_receipt(d, s)

      tampered = %{payload | "freq_start" => rfc(DateTime.add(s.freq_start, 15))}
      with_triggers_off(fn -> keep_receipt!(tampered, cols) end)

      assert raw_freq_lock(d, s) == "v6 lock receipt field freq_start does not match the draw"
    end

    test "a Land Observations receipt must sign its round's freq_start" do
      {_op, key} = create_v6_operator()
      d = open_draw_with_entries(key)
      ws = in_time_schedule()
      {payload, cols} = valid_receipt(d, ws)
      assert raw_lock(d, ws.weather_time, ws.round) == nil

      assert insert_receipt(Map.delete(payload, "freq_start"), cols) ==
               "v6 lock receipt keys are not the tag's key set"

      for bad <- [nil, rfc(DateTime.add(FreqSchedule.freq_start_for_round(ws.round), 15))] do
        assert insert_receipt(%{payload | "freq_start" => bad}, cols) ==
                 "v6 lock receipt field freq_start does not match the draw"
      end
    end
  end

  test "the lock commit-time check has a frequency arm on the commit clock" do
    %{rows: [[src]]} =
      Repo.query!("SELECT prosrc FROM pg_proc WHERE proname = 'check_v6_draw_lock_commit'")

    assert src =~ "wallop_freq_lock_allowed(clock_timestamp() AT TIME ZONE 'UTC', NEW.freq_start)"
  end

  test "expected_result_at is pub(drand_round) for frequency draws", %{draw: d, s: s} do
    assert raw_freq_lock(d, s) == nil
    locked = Ash.get!(Draw, d.id, authorize?: false, load: [:expected_result_at])
    assert locked.expected_result_at == s.expected_result_at
  end
end
