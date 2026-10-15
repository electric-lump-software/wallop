defmodule WallopCore.Weather.Stations do
  @moduledoc """
  The ordered station list of the `drand-quicknet+metoffice-landobs-v1` tag:
  Middle Wallop first, Wittering as the backup. The Land Observations API
  identifies stations only by geohash, and carries no station id, so the
  geohash-to-WMO mapping below is wallop's own.
  """

  @type station :: %{
          id: String.t(),
          wmo: String.t(),
          geohash: String.t(),
          name: String.t(),
          lat: float(),
          lon: float(),
          verified_on: Date.t()
        }

  @stations [
    %{
      id: "wmo-03749",
      wmo: "03749",
      geohash: "gcnfur",
      name: "Middle Wallop",
      lat: 51.15,
      lon: -1.57,
      verified_on: ~D[2026-10-15]
    },
    %{
      id: "wmo-03462",
      wmo: "03462",
      geohash: "gcrem9",
      name: "Wittering",
      lat: 52.61,
      lon: -0.47,
      verified_on: ~D[2026-10-15]
    }
  ]

  @doc "Every station, in the order frozen by the tag."
  @spec all() :: [station()]
  def all, do: @stations

  @doc "The station every lock receipt names."
  @spec primary() :: station()
  def primary, do: hd(@stations)

  @doc "The backup station."
  @spec backup() :: station()
  def backup, do: Enum.at(@stations, 1)

  @doc "The station ids, in order."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@stations, & &1.id)

  @spec fetch(String.t()) :: {:ok, station()} | :error
  def fetch(id) do
    case Enum.find(@stations, &(&1.id == id)) do
      nil -> :error
      station -> {:ok, station}
    end
  end
end
