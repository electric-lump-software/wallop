defmodule WallopWeb.ProofWeather do
  @moduledoc """
  What the proof page says about an observation-weather draw's entropy,
  read from the signed receipts, never from the draw row.

  Which source the draw used (Middle Wallop's reading, the grid
  frequency, or drand alone) is the execution receipt's state under the
  tag's three-state table, as `WallopCore.Protocol.Tags.LandObs.exec_state/1`
  names it. A receipt that fits none of the three states gets no source
  and is marked `out_of_table`.

  This is display only. Nothing here checks a signature; the browser
  check's verifier gate does that, and only it may show a match.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Weather.{Schedule, Stations}

  @frequency_label "Middle Wallop's reading was running late, so this draw listened to the hum " <>
                     "of the National Grid instead."
  @drand_only_label "Middle Wallop was late and the Grid went quiet, so drand did this one on its own."

  # The five keys of the three-state table. All must be present.
  @state_keys ~w(weather_value weather_observation_time weather_fallback_reason freq_value freq_fallback_reason)

  @type source :: :weather | :frequency | :drand_only
  @type t :: %{
          observation_hour: DateTime.t(),
          expected_result_at: DateTime.t(),
          source: source() | nil,
          out_of_table: boolean(),
          station_label: String.t() | nil,
          weather_value: String.t() | nil,
          observed_at: DateTime.t() | nil,
          freq_value: String.t() | nil,
          freq_start: DateTime.t() | nil,
          fallback_label: String.t() | nil,
          bmrs_line: String.t() | nil
        }

  @doc """
  The weather summary for an observation-weather draw, or nil for every
  other draw (forecast draws and grid-frequency-tag draws).

  `observation_hour` and `expected_result_at` follow from `drand_round`.
  The rest comes from the execution receipt when there is one;
  `freq_start` (the start of the grid-frequency window, T) from the
  signed lock receipt.
  """
  @spec summary(map(), map() | nil, map() | nil) :: t() | nil
  def summary(draw, execution_receipt, lock_receipt \\ nil)

  def summary(
        %{lock_schema_version: "6", drand_round: round} = draw,
        execution_receipt,
        lock_receipt
      )
      when is_integer(round) and round >= 1 do
    if Map.get(draw, :entropy_composition) == LandObs.tag() do
      base = %{
        observation_hour: Schedule.weather_time_for_round(round),
        expected_result_at: Quicknet.pub_time(round),
        source: nil,
        out_of_table: false,
        station_label: nil,
        weather_value: nil,
        observed_at: nil,
        freq_value: nil,
        freq_start: nil,
        fallback_label: nil,
        bmrs_line: nil
      }

      case execution_receipt do
        %{payload_jcs: jcs} when is_binary(jcs) ->
          Map.merge(base, from_receipt(jcs, lock_receipt))

        _ ->
          base
      end
    end
  end

  def summary(_draw, _execution_receipt, _lock_receipt), do: nil

  defp from_receipt(jcs, lock_receipt) do
    with {:ok, %{} = signed} <- Jason.decode(jcs),
         true <- signed["entropy_composition"] == LandObs.tag(),
         {:ok, source} <- state(signed) do
      for_source(source, signed, lock_receipt)
    else
      _ -> %{out_of_table: true}
    end
  end

  defp state(signed) do
    if Enum.all?(@state_keys, &Map.has_key?(signed, &1)) do
      LandObs.exec_state(%{
        weather_value: signed["weather_value"],
        weather_observation_time: parse_time(signed["weather_observation_time"]),
        weather_fallback_reason: signed["weather_fallback_reason"],
        freq_value: signed["freq_value"],
        freq_fallback_reason: signed["freq_fallback_reason"]
      })
    else
      :error
    end
  end

  defp for_source(:weather, signed, _lock_receipt) do
    %{
      source: :weather,
      station_label: station_label(signed["weather_station"]),
      weather_value: signed["weather_value"],
      observed_at: parse_time(signed["weather_observation_time"])
    }
  end

  defp for_source(:frequency, signed, lock_receipt) do
    %{
      source: :frequency,
      freq_value: signed["freq_value"],
      freq_start: lock_freq_start(lock_receipt),
      fallback_label: @frequency_label,
      bmrs_line:
        "Contains BMRS data © Elexon Limited copyright and database right #{bmrs_year(signed)}"
    }
  end

  defp for_source(:drand_only, _signed, _lock_receipt) do
    %{source: :drand_only, fallback_label: @drand_only_label}
  end

  # The readings' year, as the browser check gives it: the signed execution time's.
  defp bmrs_year(signed) do
    case parse_time(signed["executed_at"]) do
      %DateTime{year: year} -> year
      _ -> DateTime.utc_now().year
    end
  end

  defp lock_freq_start(%{payload_jcs: jcs}) when is_binary(jcs) do
    case Jason.decode(jcs) do
      {:ok, %{"freq_start" => t}} ->
        case parse_time(t) do
          %DateTime{} = dt -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp lock_freq_start(_), do: nil

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, 0} -> dt
      _ -> text
    end
  end

  defp parse_time(other), do: other

  defp station_label(id) when is_binary(id) do
    case Stations.fetch(id) do
      {:ok, s} -> "#{s.name} (WMO #{s.wmo})"
      :error -> id
    end
  end

  defp station_label(_), do: nil
end
