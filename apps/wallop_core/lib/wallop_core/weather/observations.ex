defmodule WallopCore.Weather.Observations do
  @moduledoc """
  Storage and lookups for observation-weather readings
  (`WallopCore.Resources.WeatherObservation`): one reading per observation
  hour, shared by every draw of that hour. What may be stored, and when, is
  decided by the database on its own clock; this module only asks.
  """

  require Ash.Query

  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Repo
  alias WallopCore.Resources.{Draw, WeatherObservation}

  @type reading :: %{value: String.t(), raw: String.t(), observation_time: DateTime.t()}

  @doc "The database clock, in UTC: the clock the store's window is checked on."
  @spec db_now() :: DateTime.t()
  defdelegate db_now(), to: WallopCore.DbClock, as: :now

  @doc "The reading stored for an observation hour, or nil."
  @spec for_hour(DateTime.t()) :: WeatherObservation.t() | nil
  def for_hour(%DateTime{} = weather_time) do
    WeatherObservation
    |> Ash.Query.filter(observation_time == ^weather_time)
    |> Ash.read_one!(authorize?: false)
  end

  @doc """
  The reading a draw uses: the one stored for its `weather_time`. nil for a
  draw that isn't an observation-weather draw, or whose hour has none.
  Takes the draw or its id.
  """
  @spec for_draw(Draw.t() | String.t()) :: WeatherObservation.t() | nil
  def for_draw(%Draw{lock_schema_version: "6", weather_time: %DateTime{} = wt} = draw) do
    if draw.entropy_composition == LandObs.tag(), do: for_hour(wt)
  end

  def for_draw(%Draw{}), do: nil

  def for_draw(draw_id) when is_binary(draw_id),
    do: for_draw(Ash.get!(Draw, draw_id, authorize?: false))

  @doc """
  Stores the reading for its hour (`reading.observation_time`) from a station.
  The database refuses it unless an observation-weather draw of the hour is
  waiting, the station is in its window on the database clock, nothing is
  stored for the hour yet, and the transaction commits by the fetch deadline.

  Runs in its own transaction and refuses to run inside a caller's, with
  `{:error, :nested_transaction}`: a store must commit (or fail) on its own,
  at once, and a refusal must not roll back someone else's work.
  """
  @spec store(String.t(), reading()) ::
          {:ok, WeatherObservation.t()} | {:error, :nested_transaction | term()}
  def store(station_id, %{value: value, raw: raw, observation_time: observation_time}) do
    if Repo.in_transaction?() do
      {:error, :nested_transaction}
    else
      WeatherObservation
      |> Ash.Changeset.for_create(:store, %{
        station: station_id,
        observation_time: observation_time,
        value: value,
        raw: raw
      })
      |> Ash.create(authorize?: false)
    end
  rescue
    # A refusal at COMMIT (the fetch-deadline check) surfaces here.
    e in Postgrex.Error -> {:error, e}
  end

  @doc """
  The ids of observation-weather draws for `weather_time` that are waiting for
  entropy, while nothing is stored for the hour; [] once it is.
  """
  @spec pending_draw_ids(DateTime.t()) :: [String.t()]
  def pending_draw_ids(%DateTime{} = weather_time) do
    if for_hour(weather_time) do
      []
    else
      tag = LandObs.tag()

      Draw
      |> Ash.Query.filter(
        lock_schema_version == "6" and entropy_composition == ^tag and
          weather_time == ^weather_time and status in [:awaiting_entropy, :pending_entropy]
      )
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)
    end
  end

  @doc false
  @deprecated "Use pending_draw_ids/1"
  @spec pending_v6_draw_ids(DateTime.t()) :: [String.t()]
  def pending_v6_draw_ids(weather_time), do: pending_draw_ids(weather_time)
end
