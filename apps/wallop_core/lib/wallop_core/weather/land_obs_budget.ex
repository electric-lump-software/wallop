defmodule WallopCore.Weather.LandObsBudget do
  @moduledoc """
  The daily cap on Land Observations calls (`LAND_OBS_DAILY_CAP`).

  The Met Office allows a key 900 calls a UTC day. The cap is a fuse: at
  its default it sits above the most the observation worker can spend in a
  day, so a working worker never reaches it. It trips only when something
  polls more than it should, and keeps that from using up the key's day.

  Each call is reserved first (`reserve/0`), on the counter for the
  database clock's UTC day (`WallopCore.Resources.LandObsCallCount`). A
  reservation above the cap is refused, and no call is made.
  """

  alias WallopCore.DbClock
  alias WallopCore.Resources.LandObsCallCount

  # The Met Office's daily allowance per key.
  @max_cap 900
  @default_cap 800
  # The most the worker can spend in a full day of polling: 26 polls an hour
  # (once a minute from weather_time + 5 min to F = weather_time + 30 min)
  # x 24 hours = 624. If the polling schedule changes, this changes with it.
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

  @doc "The configured cap."
  @spec cap() :: pos_integer()
  def cap, do: Application.get_env(:wallop_core, :land_obs_daily_cap, @default_cap)

  @doc """
  Reserves one call on today's counter (the database clock's UTC day).
  `{:ok, calls}` when the call may be made; `{:error, :daily_cap, calls}`
  when it would pass the cap, and must not be. `calls` is the counter after
  this reservation. Runs outside any transaction, as one statement; if it
  raises, no call may be made.
  """
  @spec reserve() :: {:ok, pos_integer()} | {:error, :daily_cap, pos_integer()}
  def reserve do
    day = DateTime.to_date(DbClock.now())

    %{calls: calls} =
      LandObsCallCount
      |> Ash.Changeset.for_create(:reserve, %{utc_day: day})
      |> Ash.create!(authorize?: false)

    if calls <= cap(), do: {:ok, calls}, else: {:error, :daily_cap, calls}
  end
end
