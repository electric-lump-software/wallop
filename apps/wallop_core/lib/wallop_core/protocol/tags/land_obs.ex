defmodule WallopCore.Protocol.Tags.LandObs do
  @moduledoc """
  Receipt rules for the `drand-quicknet+metoffice-landobs-v1` entropy tag,
  carried by lock receipt schema 6 and execution receipt schema 5.

  The lock adds `freq_start` to the lock 5 field set; the execution adds
  `freq_value` and `freq_fallback_reason` to the execution 4 field set. It
  sets the weather rules:

    * lock: `weather_station` is Middle Wallop's; `weather_time` is the
      observation hour of `drand_round` (a whole UTC hour); `freq_start` is
      the grid-frequency window start of `drand_round`, the window the tag
      falls back to; `locked_at` is no later than `weather_time` minus the
      lock offset (46 minutes), to the microsecond.
    * execution: `weather_station` is Middle Wallop's, and the receipt is
      in exactly one of three states. (a) Weather: the value matches the
      Land Observations grammar and bounds, the observation time is the
      round's observation hour, and `weather_fallback_reason`,
      `freq_value` and `freq_fallback_reason` are all nil. (b) Grid
      frequency: weather value and time are nil, the weather reason is
      `"no_observation_by_deadline"`, `freq_value` matches the
      grid-frequency grammar and `freq_fallback_reason` is nil. (c) drand
      only: as (b), but `freq_value` is nil and `freq_fallback_reason` is
      `"no_frequency_by_deadline"`. Any other combination is refused.
      `executed_at` is not earlier than the round's publication.

  Every rule here is frozen by the tag. Changing one needs a new tag.
  The constants of the grid-frequency fallback (T, K, W_freq, M, N, the
  grammar, the row rule) are those of `drand-quicknet+elexon-freq-v1`,
  frozen by this tag by reference: changing any of them changes both tags.
  """

  @behaviour WallopCore.Protocol.Tag

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.FreqGrammar
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Protocol.Tags.V6Keys
  alias WallopCore.Weather.LandObsGrammar
  alias WallopCore.Weather.Schedule
  alias WallopCore.Weather.Stations

  @tag "drand-quicknet+metoffice-landobs-v1"
  @fallback_reason "no_observation_by_deadline"
  @freq_fallback_reason "no_frequency_by_deadline"

  @doc "The entropy tag."
  @impl true
  @spec tag() :: String.t()
  def tag, do: @tag

  @doc "The only `weather_fallback_reason` the tag allows."
  @impl true
  @spec fallback_reason() :: String.t()
  def fallback_reason, do: @fallback_reason

  @doc "Every key of a lock receipt under this tag, sorted."
  @impl true
  @spec lock_keys() :: [String.t()]
  def lock_keys, do: V6Keys.lock_keys()

  @doc "Every key of an execution receipt under this tag, sorted."
  @impl true
  @spec exec_keys() :: [String.t()]
  def exec_keys, do: V6Keys.exec_keys()

  @doc "Fields the tag adds to the lock receipt: `freq_start`, the round's window start."
  @impl true
  @spec lock_fields(map()) :: map()
  def lock_fields(%{freq_start: %DateTime{} = t}),
    do: %{"freq_start" => WallopCore.Time.to_rfc3339_usec(t)}

  @doc "Fields the tag adds to the execution receipt: `freq_value`, `freq_fallback_reason`."
  @impl true
  @spec exec_fields(map()) :: map()
  def exec_fields(input),
    do: %{
      "freq_value" => Map.fetch!(input, :freq_value),
      "freq_fallback_reason" => Map.fetch!(input, :freq_fallback_reason)
    }

  @doc """
  Which of the tag's three execution states the fields are in: `:weather`
  (a), `:frequency` (b) or `:drand_only` (c); `:error` for any other
  combination. Reads only the five keys of the table.
  """
  @spec exec_state(map()) :: {:ok, :weather | :frequency | :drand_only} | :error
  def exec_state(%{} = f) do
    case {Map.get(f, :weather_value), Map.get(f, :weather_observation_time),
          Map.get(f, :weather_fallback_reason), Map.get(f, :freq_value),
          Map.get(f, :freq_fallback_reason)} do
      {v, %DateTime{}, nil, nil, nil} when is_binary(v) -> {:ok, :weather}
      {nil, nil, @fallback_reason, v, nil} when is_binary(v) -> {:ok, :frequency}
      {nil, nil, @fallback_reason, nil, @freq_fallback_reason} -> {:ok, :drand_only}
      _ -> :error
    end
  end

  @doc "Raises `ArgumentError` unless the lock input follows the tag's rules."
  @impl true
  @spec validate_lock!(map()) :: :ok
  def validate_lock!(
        %{
          weather_station: station,
          weather_time: weather_time,
          drand_round: round,
          locked_at: locked_at
        } = input
      ) do
    primary = Stations.primary().id
    require!(station == primary, "lock v6 weather_station must be #{primary}")

    require!(
      match?(%DateTime{}, weather_time) and whole_hour?(weather_time),
      "lock v6 weather_time must be a whole UTC hour"
    )

    require!(valid_round?(round), "lock v6 drand_round must be a positive integer")

    require!(
      DateTime.compare(weather_time, Schedule.weather_time_for_round(round)) == :eq,
      "lock v6 weather_time is not the observation hour for drand round #{round}"
    )

    require!(Map.has_key?(input, :freq_start), "lock v6 input must carry :freq_start")
    freq_start = Map.fetch!(input, :freq_start)

    require!(
      match?(%DateTime{}, freq_start) and
        DateTime.compare(freq_start, FreqSchedule.freq_start_for_round(round)) == :eq,
      "lock v6 freq_start is not the window start for drand round #{round}"
    )

    require!(
      match?(%DateTime{}, locked_at) and Schedule.lock_allowed?(locked_at, weather_time),
      "lock v6 locked_at is later than weather_time minus " <>
        "#{div(Schedule.lock_offset_seconds(), 60)} minutes"
    )
  end

  @doc "Raises `ArgumentError` unless the execution input follows the tag's rules."
  @impl true
  @spec validate_exec!(map()) :: :ok
  def validate_exec!(
        %{weather_station: station, drand_round: round, executed_at: executed_at} = input
      ) do
    # Present on every input, like the base keys; nil only where the rules allow it.
    for key <- [:freq_value, :freq_fallback_reason],
        do: require!(Map.has_key?(input, key), "exec v5 input must carry #{inspect(key)}")

    primary = Stations.primary().id
    require!(station == primary, "exec v5 weather_station must be #{primary}")
    require!(valid_round?(round), "exec v5 drand_round must be a positive integer")

    case exec_state(input) do
      {:ok, :weather} ->
        validate_weather!(input, round)

      {:ok, :frequency} ->
        require!(
          FreqGrammar.valid_value?(input.freq_value),
          "exec v5 freq_value does not match the grid-frequency grammar"
        )

      {:ok, :drand_only} ->
        :ok

      :error ->
        raise ArgumentError,
              "exec v5 fields must be in one of three states: a weather value and " <>
                "observation time with no reasons; no weather, reason " <>
                "#{inspect(@fallback_reason)}, a freq_value and no freq reason; or no " <>
                "weather, reason #{inspect(@fallback_reason)}, no freq_value and freq " <>
                "reason #{inspect(@freq_fallback_reason)}"
    end

    require!(
      match?(%DateTime{}, executed_at) and
        DateTime.compare(executed_at, Quicknet.pub_time(round)) != :lt,
      "exec v5 executed_at is before drand round #{round} was published"
    )
  end

  defp validate_weather!(%{weather_value: value, weather_observation_time: observed}, round) do
    # valid_value?/1 checks the grammar and the frozen bounds.
    require!(
      LandObsGrammar.valid_value?(value),
      "exec v5 weather_value does not match the Land Observations grammar and bounds"
    )

    require!(whole_hour?(observed), "exec v5 weather_observation_time must be a whole UTC hour")

    require!(
      DateTime.compare(observed, Schedule.weather_time_for_round(round)) == :eq,
      "exec v5 weather_observation_time is not the observation hour for drand round #{round}"
    )
  end

  defp valid_round?(round), do: is_integer(round) and round >= 1

  defp whole_hour?(%DateTime{} = dt),
    do: Integer.mod(DateTime.to_unix(dt), 3600) == 0 and elem(dt.microsecond, 0) == 0

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)
end
