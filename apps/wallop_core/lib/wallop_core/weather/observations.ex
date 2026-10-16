defmodule WallopCore.Weather.Observations do
  @moduledoc """
  Storage and lookups for observation-weather readings
  (`WallopCore.Resources.WeatherObservation`). What may be stored, and when,
  is decided by the database on its own clock; this module only asks.
  """

  require Ash.Query

  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Repo
  alias WallopCore.Resources.{Draw, WeatherObservation}

  @doc "The database clock, in UTC: the clock the store's window is checked on."
  @spec db_now() :: DateTime.t()
  def db_now do
    %{rows: [[naive]]} = Repo.query!("SELECT statement_timestamp() AT TIME ZONE 'UTC'")
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  @doc "The observation stored for a draw, or nil."
  @spec for_draw(String.t()) :: WeatherObservation.t() | nil
  def for_draw(draw_id) do
    WeatherObservation
    |> Ash.Query.filter(draw_id == ^draw_id)
    |> Ash.read_one!(authorize?: false)
  end

  @doc """
  Stores a reading for a draw from a station. The database refuses it unless
  the draw is a waiting observation-weather draw, the station is in its window
  on the database clock, nothing is stored for the draw yet, the value is the
  same as any stored for the station and hour, and the transaction commits by
  the fetch deadline.
  """
  @spec store(String.t(), String.t(), %{
          value: String.t(),
          raw: String.t(),
          observation_time: DateTime.t()
        }) :: {:ok, WeatherObservation.t()} | {:error, term()}
  def store(draw_id, station_id, %{value: value, raw: raw, observation_time: observation_time}) do
    WeatherObservation
    |> Ash.Changeset.for_create(:store, %{
      draw_id: draw_id,
      station: station_id,
      observation_time: observation_time,
      value: value,
      raw: raw
    })
    |> Ash.create(authorize?: false)
  rescue
    # A refusal at COMMIT (the fetch-deadline check) surfaces here.
    e in Postgrex.Error -> {:error, e}
  end

  @doc """
  The ids of observation-weather draws for `weather_time` that are waiting for
  entropy and have nothing stored yet.
  """
  @spec pending_v6_draw_ids(DateTime.t()) :: [String.t()]
  def pending_v6_draw_ids(%DateTime{} = weather_time) do
    tag = LandObs.tag()

    ids =
      Draw
      |> Ash.Query.filter(
        lock_schema_version == "6" and entropy_composition == ^tag and
          weather_time == ^weather_time and status in [:awaiting_entropy, :pending_entropy]
      )
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    stored =
      WeatherObservation
      |> Ash.Query.filter(draw_id in ^ids)
      |> Ash.Query.select([:draw_id])
      |> Ash.read!(authorize?: false)
      |> MapSet.new(& &1.draw_id)

    Enum.reject(ids, &MapSet.member?(stored, &1))
  end
end
