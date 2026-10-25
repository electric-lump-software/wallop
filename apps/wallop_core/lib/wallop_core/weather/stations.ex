defmodule WallopCore.Weather.Stations do
  @moduledoc """
  The one station of the `drand-quicknet+metoffice-landobs-v1` tag, Middle
  Wallop. The Land Observations API identifies it only by geohash and
  carries no station id, so the geohash-to-WMO mapping below is wallop's
  own.
  """

  @type station :: %{
          id: String.t(),
          wmo: String.t(),
          geohash: String.t(),
          name: String.t(),
          verified_on: Date.t()
        }

  @stations [
    %{
      id: "wmo-03749",
      wmo: "03749",
      geohash: "gcnfur",
      name: "Middle Wallop",
      verified_on: ~D[2026-10-15]
    }
  ]

  @doc "Every station of the tag: Middle Wallop alone."
  @spec all() :: [station()]
  def all, do: @stations

  @doc "The station every lock receipt names."
  @spec primary() :: station()
  def primary, do: hd(@stations)

  @doc "The station ids."
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
