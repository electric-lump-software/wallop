defmodule WallopCore.Protocol.Tags.LandObs do
  @moduledoc """
  Receipt rules for the `drand-quicknet+metoffice-landobs-v1` entropy tag,
  carried by lock receipt schema 6 and execution receipt schema 5.

  The lock adds `freq_start` to the lock 5 field set; the execution adds
  no fields to the execution 4 field set. It sets the weather rules:

    * lock: `weather_station` is Middle Wallop's; `weather_time` is the
      observation hour of `drand_round` (a whole UTC hour); `freq_start` is
      the grid-frequency window start of `drand_round`, the window the tag
      falls back to; `locked_at` is no later than `weather_time` minus the
      lock offset (46 minutes), to the microsecond.
    * execution: `weather_station` is Middle Wallop's. Either the value
      matches the Land Observations grammar and bounds, the observation
      time is the round's observation hour and the reason is nil; or value
      and time are nil and the reason is `"no_observation_by_deadline"`.
      `executed_at` is not earlier than the round's publication.

  Every rule here is frozen by the tag. Changing one needs a new tag.
  """

  @behaviour WallopCore.Protocol.Tag

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Protocol.Tags.V6Keys
  alias WallopCore.Weather.LandObsGrammar
  alias WallopCore.Weather.Schedule
  alias WallopCore.Weather.Stations

  @tag "drand-quicknet+metoffice-landobs-v1"
  @fallback_reason "no_observation_by_deadline"

  @exec_keys ~w(drand_chain drand_randomness drand_round drand_signature
                drand_signature_algorithm draw_id entropy_composition entry_hash executed_at
                fair_pick_version jcs_version lock_receipt_hash merkle_algorithm
                operator_id operator_slug results schema_version seed sequence
                signature_algorithm signing_key_id wallop_core_version
                weather_fallback_reason weather_observation_time weather_station
                weather_value)

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
  def exec_keys, do: @exec_keys

  @doc "Fields the tag adds to the lock receipt: `freq_start`, the round's window start."
  @impl true
  @spec lock_fields(map()) :: map()
  def lock_fields(%{freq_start: %DateTime{} = t}),
    do: %{"freq_start" => WallopCore.Time.to_rfc3339_usec(t)}

  @doc "Fields the tag adds to the execution receipt. None."
  @impl true
  @spec exec_fields(map()) :: map()
  def exec_fields(_input), do: %{}

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
    primary = Stations.primary().id
    require!(station == primary, "exec v5 weather_station must be #{primary}")
    require!(valid_round?(round), "exec v5 drand_round must be a positive integer")
    validate_weather!(input, round)

    require!(
      match?(%DateTime{}, executed_at) and
        DateTime.compare(executed_at, Quicknet.pub_time(round)) != :lt,
      "exec v5 executed_at is before drand round #{round} was published"
    )
  end

  defp validate_weather!(
         %{
           weather_fallback_reason: nil,
           weather_value: value,
           weather_observation_time: %DateTime{} = observed
         },
         round
       ) do
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

  defp validate_weather!(
         %{
           weather_fallback_reason: @fallback_reason,
           weather_value: nil,
           weather_observation_time: nil
         },
         _round
       ),
       do: :ok

  defp validate_weather!(_input, _round) do
    raise ArgumentError,
          "exec v5 weather fields must be a value and observation time with a null " <>
            "reason, or both null with reason #{inspect(@fallback_reason)}"
  end

  defp valid_round?(round), do: is_integer(round) and round >= 1

  defp whole_hour?(%DateTime{} = dt),
    do: Integer.mod(DateTime.to_unix(dt), 3600) == 0 and elem(dt.microsecond, 0) == 0

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)
end
