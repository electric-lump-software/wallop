defmodule WallopCore.Invariants.TamperFreqTest do
  @moduledoc """
  INV-2 for the grid-frequency tag: every signed frequency field, and every
  weather field that must stay null, is refused by the builder or the
  database; the rest reach the verifier through the tamper vectors
  (`spec/vectors/proof-bundle-v6-tamper-freq.json`).
  """
  use WallopCore.InvariantCase, async: false

  @moduletag :invariant

  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.TamperProfiles
  alias WallopCore.TamperVectors

  @weather_reason "no_observation_by_deadline"
  @either ~s(exec v5 must carry a freq_value with a null freq_fallback_reason, or a null freq_value with reason "no_frequency_by_deadline")
  @grammar "exec v5 freq_value does not match the grid-frequency grammar"

  defp lock_input, do: TamperVectors.lock_input(TamperProfiles.Freq)

  defp exec_input do
    {lock_jcs, _} = TamperVectors.base(TamperProfiles.Freq, :observed)
    TamperVectors.exec_input(TamperProfiles.Freq, :observed, lock_jcs)
  end

  defp window_message(round),
    do: "lock v6 freq_start is not the window start for drand round #{round}"

  describe "INV-2 the builders refuse every frequency-field mutation they can see" do
    test "INV-2 (tamper, frequency lock builder) each frequency-field mutation is refused with its message" do
      lock = lock_input()
      t = lock.freq_start
      round = lock.drand_round

      late =
        "lock v6 locked_at is later than freq_start minus #{FreqSchedule.lock_gap_seconds()} seconds"

      assert is_binary(Protocol.build_v6_lock_payload(lock))

      for {label, input, message} <- [
            {"freq_start +15 s", %{lock | freq_start: DateTime.add(t, 15)},
             window_message(round)},
            {"freq_start -15 s", %{lock | freq_start: DateTime.add(t, -15)},
             window_message(round)},
            {"freq_start +1 s", %{lock | freq_start: DateTime.add(t, 1)}, window_message(round)},
            {"freq_start +1 µs", %{lock | freq_start: DateTime.add(t, 1, :microsecond)},
             window_message(round)},
            {"freq_start nil", %{lock | freq_start: nil},
             "lock v6 freq_start must be a DateTime"},
            {"freq_start string", %{lock | freq_start: rfc(t)},
             "lock v6 freq_start must be a DateTime"},
            {"freq_start missing", Map.delete(lock, :freq_start),
             "lock v6 input must carry :freq_start"},
            {"round -1 alone (the window before)", %{lock | drand_round: round - 1},
             window_message(round - 1)},
            {"round +5 alone (the next window)", %{lock | drand_round: round + 5},
             window_message(round + 5)},
            {"round float", %{lock | drand_round: round * 1.0},
             "lock v6 drand_round must be a positive integer"},
            {"locked_at T - 60 s + 1 µs",
             %{lock | locked_at: DateTime.add(FreqSchedule.latest_lock_at(t), 1, :microsecond)},
             late},
            {"weather_station set", %{lock | weather_station: "wmo-03749"},
             "lock v6 under #{Freq.tag()} carries no weather_station"},
            {"weather_time set", %{lock | weather_time: ~U[2026-10-14 19:00:00.000000Z]},
             "lock v6 under #{Freq.tag()} carries no weather_time"}
          ] do
        error = assert_raise ArgumentError, fn -> Protocol.build_v6_lock_payload(input) end
        assert Exception.message(error) == message, label
      end
    end

    test "INV-2 (tamper, frequency lock builder) the round and window moved together still build" do
      # The builder can't tell the next window from this one; the database
      # binds the round to the draw (below), and the verifier has the
      # vectors' cases.
      lock = lock_input()
      next = lock.drand_round + 5

      moved = %{lock | drand_round: next, freq_start: FreqSchedule.freq_start_for_round(next)}
      payload = moved |> Protocol.build_v6_lock_payload() |> Jason.decode!()
      assert payload["drand_round"] == next
      assert payload["freq_start"] == rfc(FreqSchedule.freq_start_for_round(next))
    end

    test "INV-2 (tamper, frequency exec builder) each frequency-field mutation is refused with its message" do
      exec = exec_input()
      assert is_binary(Protocol.build_v6_execution_payload(exec))

      for {label, input, message} <- [
            {"stuck run", %{exec | freq_value: "50000;50000;50000;50000;50000;50000;50012;50013"},
             @grammar},
            {"seven readings", %{exec | freq_value: "50012;50018;50012;49983;49980;49953;49912"},
             @grammar},
            {"a zero reading",
             %{exec | freq_value: "00000;50018;50012;49983;49980;49953;49912;49883"}, @grammar},
            {"below the bounds",
             %{exec | freq_value: "46999;50018;50012;49983;49980;49953;49912;49883"}, @grammar},
            {"a number", %{exec | freq_value: 50_012}, @either},
            {"reason beside value", %{exec | freq_fallback_reason: Freq.fallback_reason()},
             @either},
            {"both null", %{exec | freq_value: nil}, @either},
            {"the weather reason",
             %{exec | freq_value: nil, freq_fallback_reason: @weather_reason}, @either},
            {"freq_value missing", Map.delete(exec, :freq_value),
             "exec v5 input must carry :freq_value"},
            {"weather_value set", %{exec | weather_value: "141;1025;85;2432"},
             "exec v5 under #{Freq.tag()} carries no weather_value"},
            {"weather_station set", %{exec | weather_station: "wmo-03749"},
             "exec v5 under #{Freq.tag()} carries no weather_station"},
            {"weather_observation_time set",
             %{exec | weather_observation_time: ~U[2026-10-14 19:00:00.000000Z]},
             "exec v5 under #{Freq.tag()} carries no weather_observation_time"},
            {"weather_fallback_reason set", %{exec | weather_fallback_reason: @weather_reason},
             "exec v5 under #{Freq.tag()} carries no weather_fallback_reason"}
          ] do
        error = assert_raise ArgumentError, fn -> Protocol.build_v6_execution_payload(input) end
        assert Exception.message(error) == message, label
      end
    end

    test "INV-2 (tamper, frequency exec builder) the Land Obs tag on a frequency input is refused" do
      # A frequency exec input under the Land Obs tag: the weather rules
      # refuse its null weather fields.
      exec = exec_input()

      assert_raise ArgumentError, fn ->
        Protocol.build_v6_execution_payload(%{exec | entropy_composition: LandObs.tag()})
      end

      assert_raise ArgumentError, fn ->
        Protocol.build_v6_lock_payload(%{lock_input() | entropy_composition: LandObs.tag()})
      end
    end
  end

  describe "INV-2 the database refuses frequency lock mutations" do
    setup do
      {_op, key} = create_freq_operator()
      draw = open_draw_with_entries(key)
      s = in_time_freq_schedule()
      {payload, cols} = valid_freq_receipt(draw, s)
      assert raw_freq_lock(draw, s) == nil
      %{s: s, payload: payload, cols: cols}
    end

    test "INV-2 (tamper, frequency lock database) round and window moved together pass the builder, not the database",
         %{s: s, payload: payload, cols: cols} do
      # The next window's round and start, consistent with each other.
      moved = %{
        payload
        | "drand_round" => s.round + 5,
          "freq_start" => rfc(FreqSchedule.freq_start_for_round(s.round + 5))
      }

      assert insert_receipt(moved, cols) ==
               "v6 lock receipt field drand_round does not match the draw"

      assert insert_receipt(payload, cols) == nil
    end

    test "INV-2 (tamper, frequency lock database) each signed frequency-tag field is bound to the draw",
         %{s: s, payload: payload, cols: cols} do
      pair = "a v6 lock receipt must carry its draw's schema and entropy_composition"
      keys = "v6 lock receipt keys are not the tag's key set"
      late = DateTime.add(s.latest_lock_at, 1, :microsecond)

      for {label, tampered, tampered_cols, message} <- [
            {"freq_start +15 s", %{payload | "freq_start" => rfc(DateTime.add(s.freq_start, 15))},
             cols, "v6 lock receipt field freq_start does not match the draw"},
            {"freq_start null", %{payload | "freq_start" => nil}, cols,
             "v6 lock receipt field freq_start does not match the draw"},
            {"freq_start missing", Map.delete(payload, "freq_start"), cols, keys},
            {"round +1 (the same window)", %{payload | "drand_round" => s.round + 1}, cols,
             "v6 lock receipt field drand_round does not match the draw"},
            {"weather_station set", %{payload | "weather_station" => "wmo-03749"}, cols,
             "v6 lock receipt field weather_station does not match the draw"},
            {"weather_time set",
             %{payload | "weather_time" => rfc(~U[2026-10-14 19:00:00.000000Z])}, cols,
             "v6 lock receipt field weather_time does not match the draw"},
            {"the Land Obs tag", %{payload | "entropy_composition" => LandObs.tag()}, cols, pair},
            {"schema 5", %{payload | "schema_version" => "5"}, cols, pair},
            {"locked_at late, column too", %{payload | "locked_at" => rfc(late)},
             %{cols | locked_at: late}, "v6 signed locked_at is too late for this draw time"}
          ] do
        assert insert_receipt(tampered, tampered_cols) == message, label
      end

      assert insert_receipt(payload, cols) == nil
    end
  end

  describe "INV-2 the database refuses frequency execution mutations" do
    test "INV-2 (tamper, frequency exec database) another valid value passes the builder, not the database" do
      x = completed_freq_receipt_input(:observed)
      other = "50012;50018;50012;49983;49980;49953;49912;49884"

      assert insert_exec_receipt(
               Protocol.build_v6_execution_payload(%{x.input | freq_value: other}),
               x.cols
             ) ==
               "v6 execution receipt field freq_value does not match the stored frequency window"

      assert insert_exec_receipt(Protocol.build_v6_execution_payload(x.input), x.cols) == nil
    end

    test "INV-2 (tamper, frequency exec database) the value, the reason and the weather fields are bound" do
      for kind <- [:observed, :fallback] do
        x = completed_freq_receipt_input(kind, minutes_ago: if(kind == :observed, do: 0, else: 2))
        payload = x.input |> Protocol.build_v6_execution_payload() |> Jason.decode!()
        assert insert_exec_receipt(Jason.encode!(payload), x.cols) == nil, "#{kind}"

        swapped =
          if kind == :observed,
            do: %{payload | "freq_value" => nil, "freq_fallback_reason" => Freq.fallback_reason()},
            else: %{
              payload
              | "freq_value" => TamperProfiles.Freq.value(),
                "freq_fallback_reason" => nil
            }

        stored = &"v6 execution receipt field #{&1} does not match the stored frequency window"
        pair = "a v6 execution receipt must be schema 5 and carry its draw's entropy_composition"

        for {label, tampered, message} <- [
              {"value and reason swapped", swapped, stored.("freq_value")},
              {"reason beside the value",
               %{payload | "freq_fallback_reason" => Freq.fallback_reason()},
               stored.("freq_fallback_reason")},
              {"the weather reason", %{payload | "freq_fallback_reason" => @weather_reason},
               stored.("freq_fallback_reason")},
              {"weather_value set", %{payload | "weather_value" => "141;1025;85;2432"},
               stored.("weather_value")},
              {"weather_station set", %{payload | "weather_station" => "wmo-03749"},
               stored.("weather_station")},
              {"weather_fallback_reason set",
               %{payload | "weather_fallback_reason" => @weather_reason},
               stored.("weather_fallback_reason")},
              {"the Land Obs tag", %{payload | "entropy_composition" => LandObs.tag()}, pair}
            ],
            # On a fallback the reason is already there.
            tampered != payload do
          assert insert_exec_receipt(Jason.encode!(tampered), x.cols) == message,
                 "#{kind}: #{label}"
        end
      end
    end
  end
end
