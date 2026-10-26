defmodule WallopWeb.ProofPdfHTMLTest do
  # The PDF's HTML, before Gotenberg: its entropy section follows the
  # signed execution receipt's state for lock schema 6 draws, and is
  # unchanged for forecast draws.
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers
  import WallopWeb.SignedEntropyHelpers

  alias WallopCore.Weather.Schedule

  defp squash(html), do: String.replace(html, ~r/\s+/, " ")

  test "forecast draw: as before" do
    api_key = create_api_key()
    draw = create_draw(api_key, %{}) |> execute_draw(test_seed(), api_key)
    html = draw |> pdf_html() |> squash()

    assert html =~ "Value (°C)"
    assert html =~ "Fetch the Met Office Middle Wallop observation for"
    assert html =~ "Combine entry hash, drand randomness, and weather value into a"
    refute html =~ "The signed receipt says"
    refute html =~ "BMRS"
  end

  test "state (a): the four-part value, labelled, and a Land Observations recipe step" do
    html = :observed |> completed_signed!() |> pdf_html() |> squash()

    assert html =~ "The signed receipt says:"
    assert html =~ "Middle Wallop (WMO 03749)"
    assert html =~ "141;1025;85;2432"
    assert html =~ "temperature (°C × 10); pressure (hPa); humidity (%); visibility (m ÷ 10)"
    refute html =~ "Value (°C)"
    assert html =~ "Within 48 hours: Met Office Land Observations (free DataHub key)."

    assert html =~
             "every part from the Met Office MIDAS hourly archive on CEDA, released each July " <>
               "for the year before"

    assert html =~ "wallop-verify weather-attest"
    assert html =~ "What you're trusting here:"
    assert html =~ "Fewer than drand&#39;s threshold of nodes collude."
    refute html =~ "Confirm the temperature value matches"
    refute html =~ "drand entropy alone"
  end

  test "the weather hour sits under 'The signed receipt says:' (no browser check on paper)" do
    html = :observed |> completed_signed!() |> pdf_html() |> squash()
    [_, after_heading] = String.split(html, "The signed receipt says:", parts: 2)

    assert after_heading =~ "Set by the draw&#39;s drand round" or
             after_heading =~ "Set by the draw's drand round"

    refute html =~ "the check above confirms it"
  end

  test "state (b): the approved line, the readings, BMRS, and never 'drand alone'" do
    draw = completed_signed!(:frequency)
    html = draw |> pdf_html() |> squash()
    year = Schedule.weather_time_for_round(draw.drand_round).year

    assert html =~
             "Middle Wallop&#39;s reading was running late, so this draw listened to the hum " <>
               "of the National Grid instead."

    assert html =~ "50012;50018;50012;49983;49980;49953;49912;49883"
    assert html =~ "Contains BMRS data © Elexon Limited copyright and database right #{year}"
    assert html =~ "Fetch Elexon's grid frequency readings"
    assert html =~ "the grid frequency readings (freq_value)"
    refute html =~ "drand entropy alone"
    refute html =~ "Value (°C)"
    refute html =~ "Met Office"
  end

  test "state (c): the approved drand-alone line" do
    html = :fallback |> completed_signed!() |> pdf_html() |> squash()

    assert html =~
             "Middle Wallop was late and the Grid went quiet, so drand did this one on its own."

    assert html =~ "Combine entry hash and drand randomness into"
    refute html =~ "BMRS"
    refute html =~ "Met Office"
    refute html =~ "drand entropy alone"
  end

  test "out of table: says so, names no source" do
    html =
      :observed
      |> completed_signed!(fn signed ->
        Map.put(signed, "freq_value", "50012;50018;50012;49983;49980;49953;49912;49883")
      end)
      |> pdf_html()
      |> squash()

    assert html =~ "doesn&#39;t match any of the three ways a weather draw can go"
    assert html =~ "names no seed source"
    refute html =~ "Weather entropy"
    refute html =~ "Grid frequency entropy"
    refute html =~ "What you're trusting here"
    refute html =~ "Met Office"
    refute html =~ "BMRS"
  end

  test "grid-frequency tag, readings: BMRS and the frequency seed step" do
    html = {:freq, :observed} |> completed_signed!() |> pdf_html() |> squash()
    assert html =~ "Grid frequency entropy"
    assert html =~ "Contains BMRS data © Elexon Limited copyright and database right"
    assert html =~ "the grid frequency readings (freq_value)"
    refute html =~ "drand entropy alone"
  end

  test "grid-frequency tag, no readings: drand alone" do
    html = {:freq, :fallback} |> completed_signed!() |> pdf_html() |> squash()
    assert html =~ "The Grid went quiet, so drand did this one on its own."
    refute html =~ "BMRS"
  end
end
