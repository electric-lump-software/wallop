defmodule WallopCore.Weather.LandObsBudget do
  @moduledoc """
  The daily cap on Land Observations calls (`LAND_OBS_DAILY_CAP`).

  The Met Office allows a key 900 calls a UTC day. The cap is a fuse: at
  its default it sits above the most the observation worker can spend in a
  day, so a working worker never reaches it. It trips only when something
  polls more than it should, and keeps that from using up the key's day.

  Each call is reserved first (`reserve/0`), on the counter for the
  database clock's UTC day (`WallopCore.Resources.LandObsCallCount`). A
  reservation above the cap is refused, and no call is made. The first
  refusal of a day is reported once (`claim_cap_report/0`).
  """

  alias WallopCore.Resources.LandObsCallCount

  require Ash.Query

  @max_cap 900
  @default_cap 800
  @full_day_calls 26 * 24

  @doc "The Met Office's daily allowance, and the largest cap accepted."
  @spec max_cap() :: pos_integer()
  def max_cap, do: @max_cap

  @doc "The cap when `LAND_OBS_DAILY_CAP` is unset."
  @spec default_cap() :: pos_integer()
  def default_cap, do: @default_cap

  @doc "The most calls a full day of polling can make; a cap below it may cause fallbacks."
  @spec full_day_calls() :: pos_integer()
  def full_day_calls, do: @full_day_calls

  @doc """
  Parses `LAND_OBS_DAILY_CAP`: unset is the default, otherwise a whole
  number from 1 to #{@max_cap}. Anything else raises, so a bad value stops
  the boot.
  """
  @spec parse_cap!(String.t() | nil) :: pos_integer()
  def parse_cap!(nil), do: @default_cap

  def parse_cap!(value) when is_binary(value) do
    case Integer.parse(value) do
      {cap, ""} when cap in 1..@max_cap//1 ->
        cap

      _ ->
        raise ArgumentError,
              "LAND_OBS_DAILY_CAP must be a whole number from 1 to #{@max_cap}, " <>
                "got #{inspect(value)}"
    end
  end

  @doc "The boot warning for `cap`, or nil when it covers a full day of polling."
  @spec boot_warning(pos_integer()) :: String.t() | nil
  def boot_warning(cap) when cap < @full_day_calls,
    do:
      "LAND_OBS_DAILY_CAP is #{cap}, below a full day of polling (#{@full_day_calls}); " <>
        "observation-weather draws may fall back"

  def boot_warning(_cap), do: nil

  @doc """
  The configured cap (`config :wallop_core, :land_obs_daily_cap`), checked:
  unset is the default, and anything but a whole number from 1 to
  #{@max_cap} raises. `WallopCore.Application` calls it at start, so a bad
  value, however it was set, stops the boot rather than leaving the cap
  open; `reserve/0` calls it before counting, so a bad value set later
  means no call.
  """
  @spec cap() :: pos_integer()
  def cap, do: validate_cap!(Application.get_env(:wallop_core, :land_obs_daily_cap))

  @doc false
  @spec validate_cap!(term()) :: pos_integer()
  def validate_cap!(nil), do: @default_cap
  def validate_cap!(cap) when is_integer(cap) and cap in 1..@max_cap//1, do: cap

  def validate_cap!(other) do
    raise ArgumentError,
          "config :wallop_core, :land_obs_daily_cap must be a whole number from 1 to " <>
            "#{@max_cap}, got #{inspect(other)}"
  end

  @doc """
  Reserves one call on today's counter (the database clock's UTC day).
  `{:ok, calls}` when the call may be made; `{:error, :daily_cap, calls}`
  when it would pass the cap, and must not be. `calls` is the counter after
  this reservation. Runs outside any transaction, as one statement; if it
  raises, no call may be made.
  """
  @spec reserve() :: {:ok, pos_integer()} | {:error, :daily_cap, pos_integer()}
  def reserve do
    cap = cap()

    %{calls: calls} =
      LandObsCallCount
      |> Ash.Changeset.for_create(:reserve, %{})
      |> Ash.create!(authorize?: false)

    if calls <= cap, do: {:ok, calls}, else: {:error, :daily_cap, calls}
  end

  @doc """
  Claims today's cap report: true for exactly one caller per UTC day (the
  database clock's), false for every other. One atomic `UPDATE ... WHERE
  NOT cap_reported`, so it holds across nodes, and holds even if the cap
  was lowered during the day.
  """
  @spec claim_cap_report() :: boolean()
  def claim_cap_report do
    %Ash.BulkResult{status: :success, records: records} =
      LandObsCallCount
      |> Ash.Query.filter(
        utc_day == fragment("(statement_timestamp() AT TIME ZONE 'UTC')::date") and
          cap_reported == false
      )
      |> Ash.bulk_update(:mark_cap_reported, %{},
        strategy: :atomic,
        return_records?: true,
        authorize?: false
      )

    records != []
  end
end
