defmodule WallopCore.Entropy.V6Rules do
  @moduledoc """
  The execution rules of a lock schema 6 draw, chosen by the draw's stored
  (lock_schema_version, entropy_composition) pair: when it may run, which
  stored reading it uses, how the seed is derived, and the fallback reason
  and station when there is no reading. Two pairs have rules: (6, Met
  Office Land Observations), `:landobs`, and (6, GB grid frequency),
  `:freq`.

  The pair is read from the draw, never from the operator's current flag.
  An unknown pair raises `ArgumentError`; nothing falls through to another
  tag's rules. A new tag adds one clause to `rules/1` and one to each
  function below.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Frequency.Windows
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  @type rules :: :landobs | :freq
  @type reading ::
          %{
            station: String.t(),
            value: String.t(),
            raw: String.t(),
            observation_time: DateTime.t()
          }
          | %{value: String.t(), raw: String.t(), freq_start: DateTime.t()}

  @doc "The rules for a draw's stored pair, or `:error` for any unknown pair."
  @spec rules(map()) :: {:ok, rules()} | :error
  def rules(%{lock_schema_version: "6", entropy_composition: tag}) do
    cond do
      tag == LandObs.tag() -> {:ok, :landobs}
      tag == Freq.tag() -> {:ok, :freq}
      true -> :error
    end
  end

  def rules(_draw), do: :error

  @doc "The rules for a draw's stored pair. Raises `ArgumentError` for any unknown pair."
  @spec rules!(map()) :: rules()
  def rules!(%{lock_schema_version: schema, entropy_composition: tag} = draw) do
    case rules(draw) do
      {:ok, rules} -> rules
      :error -> raise ArgumentError, unknown_pair_message(schema, tag)
    end
  end

  @doc """
  The refusal for an unknown pair. Same text as the draws guard's, which
  prints a NULL as `<NULL>`.
  """
  @spec unknown_pair_message(term(), term()) :: String.t()
  def unknown_pair_message(schema, tag),
    do:
      "unknown lock_schema_version and entropy_composition pair: " <>
        "(#{schema || "<NULL>"}, #{tag || "<NULL>"})"

  @doc "The end of the reading's fetch window. After it, nothing more can be stored."
  @spec fetch_deadline(rules(), map()) :: DateTime.t()
  def fetch_deadline(:landobs, draw), do: Schedule.fetch_deadline(draw.weather_time)
  def fetch_deadline(:freq, draw), do: FreqSchedule.fetch_deadline(draw.freq_start)

  @doc "When the draw's drand round publishes: the earliest it may execute."
  @spec drand_pub_time(rules(), map()) :: DateTime.t()
  def drand_pub_time(:landobs, draw), do: Quicknet.pub_time(draw.drand_round)
  def drand_pub_time(:freq, draw), do: Quicknet.pub_time(draw.drand_round)

  @doc "The reading stored for the draw, or nil."
  @spec reading(rules(), map()) :: reading() | nil
  def reading(:landobs, draw) do
    case Observations.for_draw(draw) do
      nil -> nil
      obs -> Map.take(obs, [:station, :value, :raw, :observation_time])
    end
  end

  def reading(:freq, draw) do
    case Windows.for_draw(draw) do
      nil -> nil
      window -> Map.take(window, [:value, :raw, :freq_start])
    end
  end

  @doc "The seed and its JCS preimage: with the reading, or drand alone without one."
  @spec seed(rules(), String.t(), String.t(), reading() | nil) :: {binary(), String.t()}
  def seed(:landobs, entry_hash, randomness, nil),
    do: Protocol.compute_seed(entry_hash, randomness)

  def seed(:landobs, entry_hash, randomness, %{value: value}),
    do: Protocol.compute_seed(entry_hash, randomness, value)

  def seed(:freq, entry_hash, randomness, nil),
    do: Protocol.compute_seed(entry_hash, randomness)

  def seed(:freq, entry_hash, randomness, %{value: value}),
    do: Protocol.compute_freq_seed(entry_hash, randomness, value)

  @doc """
  The draw attributes the tag sets at completion. Land Obs: the reading's
  value, raw response and observation time with no fallback reason, or all
  three nil with the fallback reason when there is no reading. Grid
  frequency: `freq_value` with no fallback reason, or nil with the reason;
  nothing else (the window's raw bytes stay in the window's own row).
  """
  @spec completion_attrs(rules(), reading() | nil) :: map()
  def completion_attrs(:landobs, nil) do
    %{
      weather_value: nil,
      weather_raw: nil,
      weather_observation_time: nil,
      weather_fallback_reason: fallback_reason(:landobs)
    }
  end

  def completion_attrs(:landobs, %{} = reading) do
    %{
      weather_value: reading.value,
      weather_raw: reading.raw,
      weather_observation_time: reading.observation_time,
      weather_fallback_reason: nil
    }
  end

  def completion_attrs(:freq, nil),
    do: %{freq_value: nil, freq_fallback_reason: fallback_reason(:freq)}

  def completion_attrs(:freq, %{value: value}),
    do: %{freq_value: value, freq_fallback_reason: nil}

  @doc """
  The tag's inputs to the execution receipt builder, from a completed draw:
  `entropy_composition`, the weather fields, and the station whose reading
  was used, read again from the store (the first station on a fallback).
  `{:error, message}` when the draw's value isn't the stored reading.

  Grid frequency: every weather field nil, and `freq_value` and
  `freq_fallback_reason` from the draw, once `freq_value` is checked
  against T's stored window again and the draw's seed is computed again
  from its inputs (the frequency seed with a value, the drand-only seed
  without). `{:error, message}` if either differs.
  """
  @spec receipt_input(rules(), map()) :: {:ok, map()} | {:error, String.t()}
  def receipt_input(:landobs, draw) do
    with {:ok, station} <- receipt_station(:landobs, draw) do
      {:ok,
       %{
         entropy_composition: draw.entropy_composition,
         weather_station: station,
         weather_observation_time: draw.weather_observation_time,
         weather_value: draw.weather_value,
         weather_fallback_reason: draw.weather_fallback_reason
       }}
    end
  end

  def receipt_input(:freq, draw) do
    with :ok <- receipt_window(draw),
         :ok <- receipt_seed(draw) do
      {:ok,
       %{
         entropy_composition: draw.entropy_composition,
         weather_station: nil,
         weather_value: nil,
         weather_observation_time: nil,
         weather_fallback_reason: nil,
         freq_value: draw.freq_value,
         freq_fallback_reason: draw.freq_fallback_reason
       }}
    end
  end

  defp receipt_station(:landobs, %{weather_value: nil}), do: {:ok, fallback_station(:landobs)}

  defp receipt_station(:landobs, draw) do
    case reading(:landobs, draw) do
      %{station: station, value: value} when value == draw.weather_value -> {:ok, station}
      _ -> {:error, "the draw's weather_value is not the stored reading for its hour"}
    end
  end

  # The signer's re-check: the value it signs is the one stored for T. On a
  # fallback there is nothing to compare; the draws guard allowed it only
  # past F + M with nothing stored.
  defp receipt_window(%{freq_value: nil}), do: :ok

  defp receipt_window(draw) do
    case reading(:freq, draw) do
      %{value: value} when value == draw.freq_value -> :ok
      _ -> {:error, "the draw's freq_value is not the stored window for its start"}
    end
  end

  # The signer's seed re-check: the seed it signs is the tag's seed of the
  # signed inputs, computed here straight from Protocol rather than through
  # seed/4, so a wrong seed clause can't sign its own output.
  defp receipt_seed(draw) do
    {bytes, _json} =
      case draw.freq_value do
        nil -> Protocol.compute_seed(draw.entry_hash, draw.drand_randomness)
        value -> Protocol.compute_freq_seed(draw.entry_hash, draw.drand_randomness, value)
      end

    if Base.encode16(bytes, case: :lower) == draw.seed,
      do: :ok,
      else: {:error, "the draw's seed is not the grid-frequency seed of its inputs"}
  end

  @doc "The fallback reason signed when there is no reading."
  @spec fallback_reason(rules()) :: String.t()
  def fallback_reason(:landobs), do: Protocol.landobs_fallback_reason()
  def fallback_reason(:freq), do: Protocol.freq_fallback_reason()

  @doc """
  The station the execution receipt names when there is no reading: the
  first one. None under the grid-frequency tag, which names no station.
  """
  @spec fallback_station(rules()) :: String.t() | nil
  def fallback_station(:landobs), do: Stations.primary().id
  def fallback_station(:freq), do: nil

  @doc """
  Telemetry metadata for `[:wallop_core, :v6, :executed]`, from a completed
  draw: the tag, the station whose reading was used (nil under the
  grid-frequency tag) and whether the draw fell back to drand alone.
  """
  @spec report_meta(rules(), map()) :: %{
          entropy_composition: String.t(),
          station: String.t() | nil,
          fallback?: boolean()
        }
  def report_meta(:landobs, draw) do
    station = with %{station: s} <- reading(:landobs, draw), do: s
    %{entropy_composition: draw.entropy_composition, station: station, fallback?: is_nil(station)}
  end

  def report_meta(:freq, draw),
    do: %{
      entropy_composition: draw.entropy_composition,
      station: nil,
      fallback?: is_nil(draw.freq_value)
    }
end
