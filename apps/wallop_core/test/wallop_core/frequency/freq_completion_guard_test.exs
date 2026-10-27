defmodule WallopCore.Frequency.FreqCompletionGuardTest do
  @moduledoc """
  The completion arm of the draws guard and the frequency arm of the
  execution receipt guard, on real geometry: the round published ten
  seconds ago, so F + M has passed, unless a test places the stored
  `freq_start` elsewhere.
  """
  use WallopCore.InvariantCase, async: false

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.Freq

  @value "50012;50018;50012;49983;49980;49953;49912;49883"
  @other "50012;50018;50012;49983;49980;49953;49912;49884"

  defp pending(freq_start \\ nil) do
    {_op, key} = create_freq_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))
    t = freq_start || FreqSchedule.freq_start_for_round(round)
    draw = put_freq_awaiting!(open_draw_with_entries(key), t, round)
    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])
    {draw, t}
  end

  defp complete(draw, set_sql, params \\ []),
    do:
      try_sql(
        "UPDATE draws SET status = 'completed', executed_at = $2, #{set_sql} WHERE id = $1",
        [dump(draw.id), NaiveDateTime.utc_now() | params]
      )

  @fallback "freq_fallback_reason = 'no_frequency_by_deadline'"
  @must_window "v6 draw must complete with its stored frequency window"
  @fallback_late "v6 draw may fall back only after the fetch deadline with nothing stored"

  describe "completion" do
    test "a stored window: only its value completes, for every draw of T" do
      {a, t} = pending()
      put_frequency_window!(t, @value)

      assert complete(a, @fallback) == @must_window
      assert complete(a, "freq_value = $3", [@other]) == @must_window
      assert complete(a, "freq_value = $3", [@value]) == nil
    end

    test "nothing stored, past F + M: only the rule's fallback completes" do
      {d, _t} = pending()
      assert complete(d, "freq_value = $3", [@value]) == @fallback_late
      assert complete(d, "freq_fallback_reason = 'no_observation_by_deadline'") == @fallback_late
      assert complete(d, @fallback) == nil
    end

    test "nothing stored, F passed but F + M not yet: the fallback waits" do
      t =
        DateTime.utc_now()
        |> DateTime.add(-(FreqSchedule.span_seconds() + FreqSchedule.fetch_window_seconds() + 5))
        |> DateTime.truncate(:second)

      {d, _} = pending(t)
      assert complete(d, @fallback) == @fallback_late
    end

    test "no weather field under this tag" do
      {d, _} = pending()

      assert complete(d, "#{@fallback}, weather_fallback_reason = 'no_observation_by_deadline'") ==
               "a grid-frequency draw carries no weather fields"
    end

    test "executed_at >= pub(R)" do
      {_op, key} = create_freq_operator()
      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 600))
      t = FreqSchedule.freq_start_for_round(round)
      d = put_freq_awaiting!(open_draw_with_entries(key), t, round)
      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(d.id)])
      assert complete(d, @fallback) == "v6 draw cannot complete before its drand round publishes"
    end
  end

  describe "the execution receipt" do
    test "the signer's receipt passes, observed and fallback" do
      for kind <- [:observed, :fallback] do
        x = completed_freq_receipt_input(kind, minutes_ago: if(kind == :observed, do: 0, else: 1))

        assert insert_exec_receipt(Protocol.build_v6_execution_payload(x.input), x.cols) == nil,
               "#{kind}"
      end
    end

    test "freq_value and freq_fallback_reason are bound to the stored window or the rule" do
      x = completed_freq_receipt_input(:observed)
      refused = &"v6 execution receipt field #{&1} does not match the stored frequency window"

      assert insert_exec_receipt(
               Protocol.build_v6_execution_payload(%{x.input | freq_value: @other}),
               x.cols
             ) ==
               refused.("freq_value")

      json = x.input |> Protocol.build_v6_execution_payload() |> Jason.decode!()

      for {field, value} <- [
            {"freq_fallback_reason", "no_frequency_by_deadline"},
            {"weather_value", "141;1025;85;2432"},
            {"weather_station", "wmo-03749"}
          ] do
        assert insert_exec_receipt(Jcs.encode(Map.put(json, field, value)), x.cols) ==
                 refused.(field),
               field
      end

      y = completed_freq_receipt_input(:fallback, minutes_ago: 1)
      fallback = y.input |> Protocol.build_v6_execution_payload() |> Jason.decode!()

      assert insert_exec_receipt(Jcs.encode(%{fallback | "freq_value" => @value}), y.cols) ==
               refused.("freq_value")
    end

    test "a fallback receipt waits until F + M" do
      t =
        DateTime.utc_now()
        |> DateTime.add(-(FreqSchedule.span_seconds() + FreqSchedule.fetch_window_seconds() + 5))
        |> DateTime.truncate(:second)

      x = completed_freq_receipt_input(:fallback, freq_start: t, triggers_off: true)

      assert insert_exec_receipt(Protocol.build_v6_execution_payload(x.input), x.cols) ==
               "a v6 execution receipt may fall back only after the fetch deadline with nothing stored"
    end

    test "the Land Observations key set is refused under the frequency tag" do
      x = completed_freq_receipt_input(:fallback)
      json = x.input |> Protocol.build_v6_execution_payload() |> Jason.decode!()

      assert insert_exec_receipt(
               Jcs.encode(Map.drop(json, ["freq_value", "freq_fallback_reason"])),
               x.cols
             ) ==
               "v6 execution receipt keys are not the tag's key set"
    end

    test "the tag is the draw's, and nothing falls through to Land Obs" do
      x = completed_freq_receipt_input(:fallback)
      json = x.input |> Protocol.build_v6_execution_payload() |> Jason.decode!()

      assert insert_exec_receipt(
               Jcs.encode(%{
                 json
                 | "entropy_composition" => Protocol.landobs_entropy_composition()
               }),
               x.cols
             ) ==
               "a v6 execution receipt must be schema 5 and carry its draw's entropy_composition"

      assert Freq.tag() == x.draw.entropy_composition
    end
  end
end
