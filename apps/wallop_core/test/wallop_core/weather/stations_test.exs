defmodule WallopCore.Weather.StationsTest do
  use ExUnit.Case, async: true
  alias WallopCore.Weather.Stations

  test "the tag has one station, Middle Wallop" do
    assert Stations.ids() == ["wmo-03749"]
    assert %{geohash: "gcnfur", name: "Middle Wallop", wmo: "03749"} = Stations.primary()
    assert Stations.all() == [Stations.primary()]
    refute function_exported?(Stations, :backup, 0)
  end

  test "fetch/1 finds Middle Wallop and nothing else" do
    assert {:ok, %{wmo: "03749"}} = Stations.fetch("wmo-03749")
    assert :error = Stations.fetch("wmo-03462")
    assert :error = Stations.fetch("wmo-03772")
  end

  test "ids satisfy the receipt weather_station charset" do
    for id <- Stations.ids(),
        do: assert(id =~ ~r/\A[a-z0-9][a-z0-9_-]*[a-z0-9]\z/ and byte_size(id) <= 32)
  end

  test "each station map has exactly the frozen keys" do
    for station <- Stations.all(),
        do: assert(Map.keys(station) |> Enum.sort() == [:geohash, :id, :name, :verified_on, :wmo])
  end
end
