defmodule WallopWeb.ProofWeather do
  @moduledoc """
  What the proof page and PDF say about a lock schema 6 draw's entropy
  (observation weather, or grid frequency), read from the signed
  receipts, never from the draw row.

  Which source the draw used is the execution receipt's state:

    * observation weather tag: the three-state table, as
      `WallopCore.Protocol.Tags.LandObs.exec_state/1` names it (Middle
      Wallop's reading, the grid frequency, or drand alone);
    * grid-frequency tag: a `freq_value` string with no reason (the
      grid frequency), or a null `freq_value` with the tag's reason
      (drand alone), and every weather field null.

  A receipt that fits none of its tag's states gets no source and is
  marked `out_of_table`.

  This is display only, and says so on the page ("The signed receipt
  says:"). Nothing here checks a signature; the browser check's
  verifier gate does that, and only it may show a match.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Weather.Stations

  @landobs_frequency_label "Middle Wallop's reading was running late, so this draw listened to " <>
                             "the hum of the National Grid instead."
  @landobs_drand_only_label "Middle Wallop was late and the Grid went quiet, so drand did this " <>
                              "one on its own."
  @freq_drand_only_label "The Grid went quiet, so drand did this one on its own."

  # The whole trusted set for each tag, kept close to the ADRs' public
  # wording (ADR-0017 Amendment A for observation weather, ADR-0018 for
  # the grid frequency). Shown in full under "What you're trusting here".
  @landobs_trust_lines [
    "Fewer than drand's threshold of nodes collude.",
    "The public weather record is honest and stays available.",
    "The weather adds a little, not a lot: it only matters if drand's threshold is broken " <>
      "and the colluders work with the operator.",
    "The lock time (locked_at) is wallop's clock.",
    "wallop settled whether it had the observation and the grid readings before the drand " <>
      "round existed. Its database refuses either recorded at the wrong time, which guards " <>
      "against bugs and break-ins but not against wallop itself: a dishonest wallop that saw " <>
      "the drand round early could choose among at most three outcomes. Seeing it early " <>
      "would take drand's network colluding, or wallop deliberately getting round its own " <>
      "database.",
    "wallop can abort a draw, but only visibly, and only before the fetch deadline, which " <>
      "is before the drand round publishes.",
    "A compromised wallop could withhold a real reading, but it must decide before drand " <>
      "publishes, so it chooses blind. A wallop colluding with drand could withhold Middle " <>
      "Wallop's reading, the grid readings, or both, to choose among at most three candidate " <>
      "seeds, so a favoured entry's odds rise at most 3×.",
    "On a fallback to the grid frequency, Elexon published what the grid actually did, and " <>
      "does not revise readings."
  ]
  @freq_trust_lines [
    "Elexon published what the grid actually did, and doesn't revise readings.",
    "wallop's clock recorded the close time honestly.",
    "wallop settled whether it had the grid readings before the drand round existed. Its " <>
      "database refuses readings or a fallback recorded at the wrong time, which guards " <>
      "against bugs and break-ins but not against wallop itself: a dishonest wallop that saw " <>
      "the drand round early could choose between two outcomes. Seeing it early would take " <>
      "drand's network colluding, or wallop deliberately getting round its own database."
  ]

  # What anyone can check afterwards, by state.
  @landobs_weather_check "Checkable with wallop-verify weather-attest: the value matches the " <>
                           "public record for that station and hour."
  @landobs_frequency_check "Checkable with wallop-verify weather-attest: for a draw that used " <>
                             "the grid frequency, freq_value matches Elexon's readings for " <>
                             "T…T+105s."
  @freq_frequency_check "Anyone can re-fetch Elexon's readings to check that wallop stored " <>
                          "what was published."

  @landobs_out_of_table "This draw's signed receipt doesn't match any of the three ways a " <>
                          "weather draw can go (Middle Wallop, the Grid, or drand alone), so " <>
                          "there's no weather source to show, and we can't vouch for it."
  @freq_out_of_table "This draw's signed receipt doesn't match either of the two ways a " <>
                       "grid-frequency draw can go (the Grid, or drand alone), so there's no " <>
                       "source to show, and we can't vouch for it."

  # The five keys of the three-state table. All must be present.
  @landobs_state_keys ~w(weather_value weather_observation_time weather_fallback_reason freq_value freq_fallback_reason)
  # Signed under the grid-frequency tag, always null.
  @freq_weather_keys ~w(weather_station weather_value weather_observation_time weather_fallback_reason)

  @type source :: :weather | :frequency | :drand_only
  @type t :: %{
          tag: :landobs | :freq,
          observation_hour: DateTime.t() | nil,
          expected_result_at: DateTime.t(),
          freq_start: DateTime.t() | nil,
          source: source() | nil,
          out_of_table: boolean(),
          out_of_table_text: String.t(),
          station_label: String.t() | nil,
          weather_value: String.t() | nil,
          observed_at: DateTime.t() | nil,
          freq_value: String.t() | nil,
          fallback_label: String.t() | nil,
          trust_lines: [String.t()],
          check_line: String.t() | nil,
          bmrs_line: String.t() | nil
        }

  @doc """
  The entropy summary for a lock schema 6 draw, or nil for every other
  draw (forecast draws keep their own markup).

  * `observation_hour` (observation weather only) and `freq_start` (T)
    are the signed lock receipt's `weather_time` and `freq_start`; nil
    without a lock receipt.
  * `expected_result_at` is pub(drand_round), as the draw's
    `expected_result_at` calculation gives it (not signed).
  * The source and its values come from the execution receipt, when
    there is one.
  """
  @spec summary(map(), map() | nil, map() | nil) :: t() | nil
  def summary(draw, execution_receipt, lock_receipt \\ nil)

  def summary(
        %{lock_schema_version: "6", drand_round: round} = draw,
        execution_receipt,
        lock_receipt
      )
      when is_integer(round) and round >= 1 do
    case tag(Map.get(draw, :entropy_composition)) do
      nil -> nil
      tag -> build(tag, round, execution_receipt, signed(lock_receipt))
    end
  end

  def summary(_draw, _execution_receipt, _lock_receipt), do: nil

  defp tag(composition) do
    cond do
      composition == LandObs.tag() -> :landobs
      composition == Freq.tag() -> :freq
      true -> nil
    end
  end

  defp build(tag, round, execution_receipt, lock) do
    freq_start = time(lock["freq_start"])

    base = %{
      tag: tag,
      observation_hour: if(tag == :landobs, do: time(lock["weather_time"])),
      expected_result_at: Quicknet.pub_time(round),
      freq_start: freq_start,
      source: nil,
      out_of_table: false,
      out_of_table_text: if(tag == :landobs, do: @landobs_out_of_table, else: @freq_out_of_table),
      station_label: nil,
      weather_value: nil,
      observed_at: nil,
      freq_value: nil,
      fallback_label: nil,
      trust_lines: [],
      check_line: nil,
      bmrs_line: nil
    }

    case execution_receipt do
      %{payload_jcs: jcs} when is_binary(jcs) ->
        bmrs_year = (freq_start || FreqSchedule.freq_start_for_round(round)).year
        Map.merge(base, from_receipt(tag, jcs, bmrs_year))

      _ ->
        base
    end
  end

  defp from_receipt(tag, jcs, bmrs_year) do
    composition = if tag == :landobs, do: LandObs.tag(), else: Freq.tag()

    with {:ok, %{} = signed} <- Jason.decode(jcs),
         true <- signed["entropy_composition"] == composition,
         {:ok, source} <- state(tag, signed) do
      for_source(tag, source, signed, bmrs_year)
    else
      _ -> %{out_of_table: true}
    end
  end

  defp state(:landobs, signed) do
    if Enum.all?(@landobs_state_keys, &Map.has_key?(signed, &1)) do
      LandObs.exec_state(%{
        weather_value: signed["weather_value"],
        weather_observation_time: time_or_text(signed["weather_observation_time"]),
        weather_fallback_reason: signed["weather_fallback_reason"],
        freq_value: signed["freq_value"],
        freq_fallback_reason: signed["freq_fallback_reason"]
      })
    else
      :error
    end
  end

  defp state(:freq, signed) do
    weather_null? =
      Enum.all?(@freq_weather_keys, &(Map.has_key?(signed, &1) and is_nil(signed[&1])))

    keys? = Map.has_key?(signed, "freq_value") and Map.has_key?(signed, "freq_fallback_reason")
    reason = Freq.fallback_reason()

    case {weather_null? and keys?, signed["freq_value"], signed["freq_fallback_reason"]} do
      {true, value, nil} when is_binary(value) -> {:ok, :frequency}
      {true, nil, ^reason} -> {:ok, :drand_only}
      _ -> :error
    end
  end

  defp for_source(tag, source, signed, bmrs_year) do
    Map.merge(
      %{source: source, trust_lines: trust_lines(tag)},
      source_fields(tag, source, signed, bmrs_year)
    )
  end

  defp source_fields(_tag, :weather, signed, _bmrs_year) do
    %{
      station_label: station_label(signed["weather_station"]),
      weather_value: signed["weather_value"],
      observed_at: time(signed["weather_observation_time"]),
      check_line: @landobs_weather_check
    }
  end

  defp source_fields(tag, :frequency, signed, bmrs_year) do
    %{
      freq_value: signed["freq_value"],
      # Under the grid-frequency tag the grid is the plan, not a fallback.
      fallback_label: if(tag == :landobs, do: @landobs_frequency_label),
      check_line: if(tag == :landobs, do: @landobs_frequency_check, else: @freq_frequency_check),
      bmrs_line: "Contains BMRS data © Elexon Limited copyright and database right #{bmrs_year}"
    }
  end

  defp source_fields(tag, :drand_only, _signed, _bmrs_year) do
    %{
      fallback_label:
        if(tag == :landobs, do: @landobs_drand_only_label, else: @freq_drand_only_label)
    }
  end

  defp trust_lines(:landobs), do: @landobs_trust_lines
  defp trust_lines(:freq), do: @freq_trust_lines

  defp signed(%{payload_jcs: jcs}) when is_binary(jcs) do
    case Jason.decode(jcs) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp signed(_), do: %{}

  # A DateTime, or nil for anything that isn't a UTC timestamp.
  defp time(value) do
    case time_or_text(value) do
      %DateTime{} = dt -> dt
      _ -> nil
    end
  end

  # Keeps an unreadable timestamp as text, so the state check refuses it.
  defp time_or_text(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, 0} -> dt
      _ -> text
    end
  end

  defp time_or_text(other), do: other

  defp station_label(id) when is_binary(id) do
    case Stations.fetch(id) do
      {:ok, s} -> "#{s.name} (WMO #{s.wmo})"
      :error -> id
    end
  end

  defp station_label(_), do: nil
end
