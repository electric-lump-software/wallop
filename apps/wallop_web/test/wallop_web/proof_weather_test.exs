defmodule WallopWeb.ProofWeatherTest do
  use ExUnit.Case, async: true

  alias WallopWeb.ProofWeather

  @vectors Path.expand("../../../../spec/vectors", __DIR__)
  @landobs "drand-quicknet+metoffice-landobs-v1"

  # Round 33_068_212 publishes at 2026-10-14 20:00:00Z; its observation
  # hour is 19:00Z. The row's weather_time is deliberately another hour:
  # the page must follow the round, not the row.
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
     %{payload_jcs: b["lock_receipt"]["payload_jcs"]}}
  end

  defp edit(%{payload_jcs: jcs}, fun),
    do: %{payload_jcs: jcs |> Jason.decode!() |> fun.() |> Jason.encode!()}

  test "nil for forecast draws and for grid-frequency-tag draws" do
    {exec, lock} = receipts("proof-bundle-v6.json")

    assert ProofWeather.summary(
             %{@draw | lock_schema_version: nil, entropy_composition: nil},
             exec,
             lock
           ) == nil

    assert ProofWeather.summary(
             %{@draw | entropy_composition: "drand-quicknet+elexon-freq-v1"},
             exec,
             lock
           ) ==
             nil
  end

  test "before execution: the hour and the result time follow from the round; no source yet" do
    assert %{
             observation_hour: ~U[2026-10-14 19:00:00.000000Z],
             expected_result_at: ~U[2026-10-14 20:00:00.000000Z],
             source: nil,
             station_label: nil,
             fallback_label: nil,
             out_of_table: false
           } = ProofWeather.summary(@draw, nil)
  end

  test "state (a): Middle Wallop's reading, from the signed receipt" do
    {exec, lock} = receipts("proof-bundle-v6.json")

    assert %{
             source: :weather,
             station_label: "Middle Wallop (WMO 03749)",
             weather_value: "123;1012;67;3450",
             observed_at: ~U[2026-10-14 19:00:00.000000Z],
             fallback_label: nil,
             bmrs_line: nil,
             out_of_table: false
           } = ProofWeather.summary(@draw, exec, lock)
  end

  test "state (b): the grid frequency, with the BMRS line and the window start" do
    {exec, lock} = receipts("proof-bundle-v6-freq-window.json")

    assert %{
             source: :frequency,
             freq_value: "50012;50018;50012;49983;49980;49953;49912;49883",
             freq_start: ~U[2026-10-14 19:54:00.000000Z],
             fallback_label:
               "Middle Wallop's reading was running late, so this draw listened to the hum of the National Grid instead.",
             bmrs_line: "Contains BMRS data © Elexon Limited copyright and database right 2026",
             out_of_table: false
           } = ProofWeather.summary(@draw, exec, lock)
  end

  test "state (c): drand alone" do
    {exec, lock} = receipts("proof-bundle-v6-fallback.json")

    assert %{
             source: :drand_only,
             fallback_label:
               "Middle Wallop was late and the Grid went quiet, so drand did this one on its own.",
             bmrs_line: nil,
             out_of_table: false
           } = ProofWeather.summary(@draw, exec, lock)
  end

  test "the source is the receipt's state, never which value happens to be there" do
    {exec, lock} = receipts("proof-bundle-v6.json")
    # A weather value and a freq_value together fit none of the three states.
    bad =
      edit(exec, &Map.put(&1, "freq_value", "50012;50018;50012;49983;49980;49953;49912;49883"))

    assert %{
             source: nil,
             station_label: nil,
             fallback_label: nil,
             bmrs_line: nil,
             out_of_table: true
           } =
             ProofWeather.summary(@draw, bad, lock)
  end

  test "out of the table: a key missing, an unreadable time, another tag" do
    {exec, lock} = receipts("proof-bundle-v6-fallback.json")
    {wx, _} = receipts("proof-bundle-v6.json")

    for bad <- [
          edit(exec, &Map.delete(&1, "freq_value")),
          edit(wx, &Map.put(&1, "weather_observation_time", "yesterday")),
          edit(exec, &Map.put(&1, "entropy_composition", "drand-quicknet+elexon-freq-v1")),
          %{payload_jcs: "not json"}
        ] do
      assert %{source: nil, out_of_table: true} = ProofWeather.summary(@draw, bad, lock)
    end
  end

  test "no window start without a lock receipt" do
    {exec, _lock} = receipts("proof-bundle-v6-freq-window.json")
    assert %{source: :frequency, freq_start: nil} = ProofWeather.summary(@draw, exec, nil)
  end
end
