defmodule WallopCore.Weather.LandObsThreeStateTest do
  @moduledoc """
  Under the observation-weather tag an execution is in exactly one of
  three states: (a) Middle Wallop's reading; (b) no reading by F, so the
  round's grid-frequency window; (c) neither, so drand alone. Elixir side:
  the tag's rules, the executor's rules and the proof bundle.
  """
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo
  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{DrandClient, ObservationDrawWorker, V6Rules}
  alias WallopCore.InvariantCase
  alias WallopCore.ProofBundle
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs, V6Keys}
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.Schedule

  @value "141;1025;85;2432"
  @freq "50012;50018;50012;49983;49980;49953;49912;49883"
  @no_obs "no_observation_by_deadline"
  @no_freq "no_frequency_by_deadline"
  @wt ~U[2026-10-14 19:00:00.000000Z]
  # A real quicknet beacon: the randomness is sha256 of the signature.
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @signature "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"

  defp fields(v, o, r, f, fr),
    do: %{
      weather_value: v,
      weather_observation_time: o,
      weather_fallback_reason: r,
      freq_value: f,
      freq_fallback_reason: fr
    }

  test "exec_state/1 is the three-state table and nothing else" do
    assert LandObs.exec_state(fields(@value, @wt, nil, nil, nil)) == {:ok, :weather}
    assert LandObs.exec_state(fields(nil, nil, @no_obs, @freq, nil)) == {:ok, :frequency}
    assert LandObs.exec_state(fields(nil, nil, @no_obs, nil, @no_freq)) == {:ok, :drand_only}

    for bad <- [
          fields(@value, @wt, nil, @freq, nil),
          fields(@value, @wt, nil, nil, @no_freq),
          fields(nil, nil, @no_obs, nil, nil),
          fields(nil, nil, nil, @freq, nil),
          fields(nil, nil, @no_obs, @freq, @no_freq),
          fields(@value, nil, nil, nil, nil),
          fields(nil, @wt, @no_obs, nil, @no_freq),
          fields(nil, nil, "unreachable", nil, @no_freq),
          fields(nil, nil, @no_obs, nil, "other")
        ] do
      assert LandObs.exec_state(bad) == :error, inspect(bad)
    end

    assert LandObs.exec_keys() == V6Keys.exec_keys()
    assert Freq.exec_keys() == V6Keys.exec_keys()
    assert length(V6Keys.exec_keys()) == 28
    assert LandObs.fallback_reason() == @no_obs and Freq.fallback_reason() == @no_freq
  end

  test "the builder signs all five fields and refuses any combination outside the table" do
    base = landobs_exec_input()
    pub = Quicknet.pub_time(base.drand_round)

    for {f, state} <- [
          {fields(@value, Schedule.weather_time_for_round(base.drand_round), nil, nil, nil), :a},
          {fields(nil, nil, @no_obs, @freq, nil), :b},
          {fields(nil, nil, @no_obs, nil, @no_freq), :c}
        ] do
      payload = Jason.decode!(Protocol.build_v6_execution_payload(Map.merge(base, f)))
      assert map_size(payload) == 28, "#{state}"
      assert payload["weather_station"] == "wmo-03749", "#{state}"
      assert payload["freq_value"] == f.freq_value, "#{state}"
      assert payload["freq_fallback_reason"] == f.freq_fallback_reason, "#{state}"
    end

    for f <- [
          fields(@value, @wt, nil, @freq, nil),
          fields(nil, nil, @no_obs, nil, nil),
          fields(nil, nil, nil, @freq, nil),
          fields(nil, nil, @no_obs, "1;2", nil)
        ] do
      assert_raise ArgumentError, fn ->
        Protocol.build_v6_execution_payload(Map.merge(base, f) |> Map.put(:executed_at, pub))
      end
    end
  end

  test "state (a) ignores a stored window; (b) uses it; (c) has neither" do
    {_op, key} = create_v6_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))
    wt = Schedule.weather_time_for_round(round)

    a = put_v6_awaiting!(open_draw_with_entries(key), wt, round)
    put_frequency_window!(a.freq_start, @freq)
    put_observation!("wmo-03749", wt, @value)
    reading = V6Rules.reading(:landobs, a)
    assert %{station: "wmo-03749", value: @value} = reading

    assert V6Rules.completion_attrs(:landobs, reading)
           |> Map.take([:freq_value, :freq_fallback_reason]) ==
             %{freq_value: nil, freq_fallback_reason: nil}

    assert %{station: "wmo-03749", fallback?: false, source: :weather} =
             V6Rules.report_meta(:landobs, a)
  end

  test "(b) and (c) from stored state, with the right seeds" do
    {_op, key} = create_v6_operator()
    # Two hours back, so this hour has no stored reading from other tests.
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -7200))
    wt = Schedule.weather_time_for_round(round)
    b = put_v6_awaiting!(open_draw_with_entries(key), wt, round)
    assert V6Rules.reading(:landobs, b) == nil

    put_frequency_window!(b.freq_start, @freq)
    reading = V6Rules.reading(:landobs, b)
    assert %{value: @freq, freq_start: _} = reading

    assert V6Rules.completion_attrs(:landobs, reading) ==
             %{
               weather_value: nil,
               weather_raw: nil,
               weather_observation_time: nil,
               weather_fallback_reason: @no_obs,
               freq_value: @freq,
               freq_fallback_reason: nil
             }

    assert V6Rules.seed(:landobs, b.entry_hash, String.duplicate("ab", 32), reading) ==
             Protocol.compute_freq_seed(b.entry_hash, String.duplicate("ab", 32), @freq)

    assert V6Rules.completion_attrs(:landobs, nil) ==
             %{
               weather_value: nil,
               weather_raw: nil,
               weather_observation_time: nil,
               weather_fallback_reason: @no_obs,
               freq_value: nil,
               freq_fallback_reason: @no_freq
             }

    assert V6Rules.seed(:landobs, b.entry_hash, String.duplicate("ab", 32), nil) ==
             Protocol.compute_seed(b.entry_hash, String.duplicate("ab", 32))

    assert %{station: nil, fallback?: true, source: :frequency} =
             V6Rules.report_meta(:landobs, b)

    # (c): another hour, with nothing stored for it or its window.
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10_800))

    c =
      put_v6_awaiting!(open_draw_with_entries(key), Schedule.weather_time_for_round(round), round)

    assert V6Rules.reading(:landobs, c) == nil

    assert %{station: nil, fallback?: true, source: :drand_only} =
             V6Rules.report_meta(:landobs, c)
  end

  describe "executed through the worker" do
    setup do
      ensure_infrastructure_key()

      Application.put_env(:wallop_core, DrandClient,
        req_options: [plug: {Req.Test, DrandClient}, retry: false]
      )

      # Echoes the requested round, so the client's round check passes.
      Req.Test.stub(DrandClient, fn conn ->
        round = conn.path_info |> List.last() |> String.to_integer()

        Req.Test.json(conn, %{
          "round" => round,
          "randomness" => @randomness,
          "signature" => @signature
        })
      end)

      on_exit(fn -> Application.delete_env(:wallop_core, DrandClient) end)
    end

    # A weather-tag draw whose round published `ago` seconds ago, so every
    # deadline has passed. Each state uses a different hour and window.
    defp executed(key, ago, store) do
      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -ago))
      wt = Schedule.weather_time_for_round(round)
      draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)

      case store do
        :weather -> put_observation!("wmo-03749", wt, @value)
        :frequency -> put_frequency_window!(draw.freq_start, @freq)
        :none -> :ok
      end

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
      done = Ash.get!(Draw, draw.id, authorize?: false)
      assert done.status == :completed
      done
    end

    defp entropy(draw) do
      {:ok, json} = ProofBundle.build(draw)
      Jason.decode!(json)["entropy"]
    end

    defp exec_payload(draw) do
      %{execution_receipt: r} = Ash.load!(draw, :execution_receipt, authorize?: false)
      Jason.decode!(r.payload_jcs)
    end

    test "each state completes from stored state, with its seed, receipt and telemetry" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :executed]])
      {_op, key} = create_v6_operator()

      a = executed(key, 10, :weather)
      b = executed(key, 3610, :frequency)
      c = executed(key, 7210, :none)

      {seed_a, _} = Protocol.compute_seed(a.entry_hash, @randomness, @value)
      {seed_b, _} = Protocol.compute_freq_seed(b.entry_hash, @randomness, @freq)
      {seed_c, _} = Protocol.compute_seed(c.entry_hash, @randomness)

      for {d, seed, state, weather, reason, freq, freq_reason} <- [
            {a, seed_a, :weather, @value, nil, nil, nil},
            {b, seed_b, :frequency, nil, @no_obs, @freq, nil},
            {c, seed_c, :drand_only, nil, @no_obs, nil, @no_freq}
          ] do
        assert d.seed == Base.encode16(seed, case: :lower), "#{state}"

        assert {d.weather_value, d.weather_fallback_reason, d.freq_value, d.freq_fallback_reason} ==
                 {weather, reason, freq, freq_reason},
               "#{state}"

        p = exec_payload(d)
        assert map_size(p) == 28
        assert p["weather_station"] == "wmo-03749"

        assert {p["weather_value"], p["weather_fallback_reason"], p["freq_value"],
                p["freq_fallback_reason"]} == {weather, reason, freq, freq_reason},
               "#{state}"

        assert_receive {[:wallop_core, :v6, :executed], ^ref, _, %{source: ^state}}
      end
    end

    test "the proof bundle's entropy carries the value that fed the seed" do
      {_op, key} = create_v6_operator()

      # (a) entropy has weather_value and no freq_value.
      a = entropy(executed(key, 10, :weather))
      assert a["weather_value"] == @value
      refute Map.has_key?(a, "freq_value")

      # (b) entropy has freq_value and no weather_value.
      b = entropy(executed(key, 3610, :frequency))
      assert b["freq_value"] == @freq
      refute Map.has_key?(b, "weather_value")

      # (c) entropy has neither.
      c = entropy(executed(key, 7210, :none))
      refute Map.has_key?(c, "weather_value")
      refute Map.has_key?(c, "freq_value")
    end

    test "the bundle serves the reading first: a freq_value stored beside it is never served" do
      {_op, key} = create_v6_operator()
      a = executed(key, 10, :weather)

      # Stored state the draws guard refuses: a window beside a reading.
      InvariantCase.with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET freq_value = $2 WHERE id = $1", [
          Ecto.UUID.dump!(a.id),
          @freq
        ])
      end)

      tampered = Ash.get!(Draw, a.id, authorize?: false)
      assert tampered.freq_value == @freq
      e = entropy(tampered)
      assert e["weather_value"] == @value
      refute Map.has_key?(e, "freq_value")
    end
  end
end
