defmodule WallopCore.Protocol.Tags.Freq do
  @moduledoc """
  Receipt rules for the `drand-quicknet+elexon-freq-v1` entropy tag (GB grid
  frequency), carried by lock receipt schema 6 and execution receipt
  schema 5.

    * lock: adds `freq_start`, the window start T derived from
      `drand_round`; `weather_station` and `weather_time` are null;
      `locked_at` is no later than T minus 60 seconds, to the microsecond.
    * execution: adds `freq_value` and `freq_fallback_reason`. Either the
      value matches the grid-frequency grammar and the reason is null, or
      the value is null and the reason is `"no_frequency_by_deadline"`.
      Every `weather_*` field is null. `executed_at` is not earlier than
      the round's publication.

  `weather_*` fields are never reused: a signed field must not change
  meaning by tag. Every rule here is frozen by the tag.
  """

  @behaviour WallopCore.Protocol.Tag

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.{FreqGrammar, Schedule}

  @tag "drand-quicknet+elexon-freq-v1"
  @fallback_reason "no_frequency_by_deadline"
  @exec_weather_keys [
    :weather_station,
    :weather_value,
    :weather_observation_time,
    :weather_fallback_reason
  ]

  # Sorted bytewise, like Tags.LandObs's: the SQL key sets (F5) are
  # compared to array_agg(k ORDER BY k COLLATE "C").
  @lock_keys ~w(commitment_hash drand_chain drand_round draw_id entropy_composition
                entry_hash fair_pick_version freq_start jcs_version locked_at
                operator_id operator_slug schema_version sequence
                signature_algorithm signing_key_id wallop_core_version
                weather_station weather_time winner_count)

  @exec_keys ~w(drand_chain drand_randomness drand_round drand_signature
                drand_signature_algorithm draw_id entropy_composition entry_hash executed_at
                fair_pick_version freq_fallback_reason freq_value jcs_version
                lock_receipt_hash merkle_algorithm operator_id operator_slug results
                schema_version seed sequence signature_algorithm signing_key_id
                wallop_core_version weather_fallback_reason weather_observation_time
                weather_station weather_value)

  @doc "The entropy tag."
  @impl true
  @spec tag() :: String.t()
  def tag, do: @tag

  @doc "The only `freq_fallback_reason` the tag allows."
  @impl true
  @spec fallback_reason() :: String.t()
  def fallback_reason, do: @fallback_reason

  @doc "Every key of a lock receipt under this tag, sorted."
  @impl true
  @spec lock_keys() :: [String.t()]
  def lock_keys, do: @lock_keys

  @doc "Every key of an execution receipt under this tag, sorted."
  @impl true
  @spec exec_keys() :: [String.t()]
  def exec_keys, do: @exec_keys

  @doc "Fields the tag adds to the lock receipt: `freq_start`."
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

  @doc "Raises `ArgumentError` unless the lock input follows the tag's rules."
  @impl true
  @spec validate_lock!(map()) :: :ok
  def validate_lock!(
        %{weather_station: station, weather_time: wt, drand_round: round, locked_at: locked_at} =
          input
      ) do
    require_keys!(input, "lock v6", [:freq_start])
    require!(is_nil(station), "lock v6 under #{@tag} carries no weather_station")
    require!(is_nil(wt), "lock v6 under #{@tag} carries no weather_time")
    require!(valid_round?(round), "lock v6 drand_round must be a positive integer")
    freq_start = Map.fetch!(input, :freq_start)
    require!(match?(%DateTime{}, freq_start), "lock v6 freq_start must be a DateTime")

    require!(
      DateTime.compare(freq_start, Schedule.freq_start_for_round(round)) == :eq,
      "lock v6 freq_start is not the window start for drand round #{round}"
    )

    require!(
      match?(%DateTime{}, locked_at) and Schedule.lock_allowed?(locked_at, freq_start),
      "lock v6 locked_at is later than freq_start minus #{Schedule.lock_gap_seconds()} seconds"
    )
  end

  @doc "Raises `ArgumentError` unless the execution input follows the tag's rules."
  @impl true
  @spec validate_exec!(map()) :: :ok
  def validate_exec!(%{drand_round: round, executed_at: executed_at} = input) do
    # Present on every input, like the base keys; nil only where the rules allow it.
    require_keys!(input, "exec v5", [:freq_value, :freq_fallback_reason])

    Enum.each(@exec_weather_keys, fn key ->
      require!(is_nil(Map.get(input, key)), "exec v5 under #{@tag} carries no #{key}")
    end)

    require!(valid_round?(round), "exec v5 drand_round must be a positive integer")
    validate_freq!(Map.fetch!(input, :freq_value), Map.fetch!(input, :freq_fallback_reason))

    require!(
      match?(%DateTime{}, executed_at) and
        DateTime.compare(executed_at, Quicknet.pub_time(round)) != :lt,
      "exec v5 executed_at is before drand round #{round} was published"
    )
  end

  defp validate_freq!(value, nil) when is_binary(value),
    do:
      require!(
        FreqGrammar.valid_value?(value),
        "exec v5 freq_value does not match the grid-frequency grammar"
      )

  defp validate_freq!(nil, @fallback_reason), do: :ok

  defp validate_freq!(_value, _reason) do
    raise ArgumentError,
          "exec v5 must carry a freq_value with a null freq_fallback_reason, or a null " <>
            "freq_value with reason #{inspect(@fallback_reason)}"
  end

  defp valid_round?(round), do: is_integer(round) and round >= 1

  defp require_keys!(input, receipt, keys) do
    Enum.each(keys, fn key ->
      require!(Map.has_key?(input, key), "#{receipt} input must carry #{inspect(key)}")
    end)
  end

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)
end
