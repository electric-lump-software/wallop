defmodule WallopWeb.ProofWeatherTest do
  use ExUnit.Case, async: true

  alias WallopWeb.ProofWeather

  @vectors Path.expand("../../../../spec/vectors", __DIR__)
  @landobs "drand-quicknet+metoffice-landobs-v1"
  @freq "drand-quicknet+elexon-freq-v1"

  # Round 33_068_212 publishes at 2026-10-14 20:00:00Z; its signed
  # observation hour is 19:00Z. The row's weather_time is deliberately
  # another hour: the page follows the signed receipt, not the row.
  @draw %{
    lock_schema_version: "6",
    entropy_composition: @landobs,
    weather_time: ~U[2026-10-14 18:00:00.000000Z],
    drand_round: 33_068_212
  }

  defp receipts(file) do
    bundle = File.read!(Path.join(@vectors, file)) |> Jason.decode!() |> Map.fetch!("bundle")
    b = Jason.decode!(bundle)

    {%{payload_jcs: b["execution_receipt"]["payload_jcs"]},
     %{payload_jcs: b["lock_receipt"]["payload_jcs"]},
     Jason.decode!(b["execution_receipt"]["payload_jcs"])["drand_round"]}
  end

  defp edit(%{payload_jcs: jcs}, fun),
    do: %{payload_jcs: jcs |> Jason.decode!() |> fun.() |> Jason.encode!()}

  defp freq_draw(round), do: %{@draw | entropy_composition: @freq, drand_round: round}

  test "nil for forecast draws and for unknown tags" do
    {exec, lock, _} = receipts("proof-bundle-v6.json")

    assert ProofWeather.summary(
             %{@draw | lock_schema_version: nil, entropy_composition: nil},
             exec,
             lock
           ) == nil

    assert ProofWeather.summary(%{@draw | entropy_composition: "something-else"}, exec, lock) ==
             nil
  end

  test "before execution: the signed hour, the result time from the round, no source yet" do
    {_exec, lock, _} = receipts("proof-bundle-v6.json")

    assert %{
             tag: :landobs,
             observation_hour: ~U[2026-10-14 19:00:00.000000Z],
             freq_start: ~U[2026-10-14 19:54:00.000000Z],
             expected_result_at: ~U[2026-10-14 20:00:00.000000Z],
             source: nil,
             station_label: nil,
             fallback_label: nil,
             out_of_table: false
           } = ProofWeather.summary(@draw, nil, lock)
  end

  test "the hour shown is the lock receipt's signed weather_time, not the round's or the row's" do
    {exec, lock, _} = receipts("proof-bundle-v6.json")
    lock = edit(lock, &Map.put(&1, "weather_time", "2026-10-14T17:00:00.000000Z"))

    assert %{observation_hour: ~U[2026-10-14 17:00:00.000000Z]} =
             ProofWeather.summary(@draw, exec, lock)

    assert %{observation_hour: nil, freq_start: nil} = ProofWeather.summary(@draw, exec, nil)
  end

  test "state (a): Middle Wallop's reading, from the signed receipt" do
    {exec, lock, _} = receipts("proof-bundle-v6.json")

    assert %{
             source: :weather,
             station_label: "Middle Wallop (WMO 03749)",
             weather_value: "123;1012;67;3450",
             observed_at: ~U[2026-10-14 19:00:00.000000Z],
             fallback_label: nil,
             trust_lines: [],
             bmrs_line: nil,
             out_of_table: false
           } = ProofWeather.summary(@draw, exec, lock)
  end

  test "state (b): the grid frequency, with the trust lines and the BMRS line" do
    {exec, lock, _} = receipts("proof-bundle-v6-freq-window.json")

    assert %{
             source: :frequency,
             freq_value: "50012;50018;50012;49983;49980;49953;49912;49883",
             freq_start: ~U[2026-10-14 19:54:00.000000Z],
             fallback_label:
               "Middle Wallop's reading was running late, so this draw listened to the hum of the National Grid instead.",
             trust_lines: [
               "Trusted: on a fallback to the grid frequency, Elexon published what the grid actually did, and does not revise readings.",
               "Proven with weather-attest: for a draw that used the grid frequency, freq_value matches Elexon's readings for T…T+105s."
             ],
             bmrs_line: "Contains BMRS data © Elexon Limited copyright and database right 2026",
             out_of_table: false
           } = ProofWeather.summary(@draw, exec, lock)
  end

  test "the BMRS year is the year of T, the readings' window start" do
    {exec, lock, _} = receipts("proof-bundle-v6-freq-window.json")
    lock = edit(lock, &Map.put(&1, "freq_start", "2025-12-31T23:54:00.000000Z"))
    exec = edit(exec, &Map.put(&1, "executed_at", "2027-01-01T00:00:05.000000Z"))

    assert %{bmrs_line: "Contains BMRS data © Elexon Limited copyright and database right 2025"} =
             ProofWeather.summary(@draw, exec, lock)
  end

  test "state (c): drand alone" do
    {exec, lock, _} = receipts("proof-bundle-v6-fallback.json")

    assert %{
             source: :drand_only,
             fallback_label:
               "Middle Wallop was late and the Grid went quiet, so drand did this one on its own.",
             trust_lines: [],
             bmrs_line: nil,
             out_of_table: false
           } = ProofWeather.summary(@draw, exec, lock)
  end

  test "the source is the receipt's state, never which value happens to be there" do
    {exec, lock, _} = receipts("proof-bundle-v6.json")
    # A weather value and a freq_value together fit none of the three states.
    bad =
      edit(exec, &Map.put(&1, "freq_value", "50012;50018;50012;49983;49980;49953;49912;49883"))

    assert %{
             source: nil,
             station_label: nil,
             fallback_label: nil,
             bmrs_line: nil,
             trust_lines: [],
             out_of_table: true,
             out_of_table_text: text
           } = ProofWeather.summary(@draw, bad, lock)

    assert text =~ "doesn't match any of the three ways a weather draw can go"
  end

  test "out of the table: a key missing, an unreadable time, another tag" do
    {exec, lock, _} = receipts("proof-bundle-v6-fallback.json")
    {wx, _, _} = receipts("proof-bundle-v6.json")

    for bad <- [
          edit(exec, &Map.delete(&1, "freq_value")),
          edit(wx, &Map.put(&1, "weather_observation_time", "yesterday")),
          edit(exec, &Map.put(&1, "entropy_composition", @freq)),
          %{payload_jcs: "not json"}
        ] do
      assert %{source: nil, out_of_table: true} = ProofWeather.summary(@draw, bad, lock)
    end
  end

  describe "grid-frequency tag" do
    test "readings: the grid, its own trust lines, BMRS, no fallback sentence" do
      {exec, lock, round} = receipts("proof-bundle-v6-freq.json")

      assert %{
               tag: :freq,
               observation_hour: nil,
               source: :frequency,
               freq_value: value,
               freq_start: %DateTime{} = t,
               fallback_label: nil,
               trust_lines: [
                 "Trusted: Elexon published what the grid actually did, and doesn't revise readings.",
                 "Anyone can re-fetch Elexon's readings to check that wallop stored what was published."
               ],
               bmrs_line: bmrs,
               out_of_table: false
             } = ProofWeather.summary(freq_draw(round), exec, lock)

      assert is_binary(value)
      assert bmrs == "Contains BMRS data © Elexon Limited copyright and database right #{t.year}"
    end

    test "no readings: drand alone" do
      {exec, lock, round} = receipts("proof-bundle-v6-freq-fallback.json")

      assert %{
               source: :drand_only,
               fallback_label: "The Grid went quiet, so drand did this one on its own.",
               bmrs_line: nil,
               trust_lines: []
             } = ProofWeather.summary(freq_draw(round), exec, lock)
    end

    test "anything else is out of table, with no label" do
      {exec, lock, round} = receipts("proof-bundle-v6-freq.json")
      {fb, _, _} = receipts("proof-bundle-v6-freq-fallback.json")

      for bad <- [
            edit(exec, &Map.put(&1, "freq_fallback_reason", "no_frequency_by_deadline")),
            edit(fb, &Map.put(&1, "freq_fallback_reason", nil)),
            edit(exec, &Map.put(&1, "weather_value", "123;1012;67;3450")),
            edit(exec, &Map.delete(&1, "weather_station")),
            edit(exec, &Map.put(&1, "entropy_composition", @landobs))
          ] do
        assert %{
                 source: nil,
                 out_of_table: true,
                 fallback_label: nil,
                 bmrs_line: nil,
                 out_of_table_text: text
               } = ProofWeather.summary(freq_draw(round), bad, lock)

        assert text =~ "doesn't match either way a grid-frequency draw can go"
      end
    end
  end
end
