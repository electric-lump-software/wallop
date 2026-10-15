defmodule WallopCore.Weather.StationsTest do
  use ExUnit.Case, async: true
  alias WallopCore.Weather.Stations

  test "the ordered list frozen by the tag" do
    assert Stations.ids() == ["wmo-03749", "wmo-03462"]

    assert %{geohash: "gcnfur", name: "Middle Wallop"} =
             Stations.primary()

    assert %{geohash: "gcrem9", name: "Wittering"} = Stations.backup()
  end

  test "ids satisfy the receipt weather_station charset" do
    for id <- Stations.ids(),
        do: assert(id =~ ~r/\A[a-z0-9][a-z0-9_-]*[a-z0-9]\z/ and byte_size(id) <= 32)
  end

  test "fetch/1 finds by id" do
    assert {:ok, %{wmo: "03462"}} = Stations.fetch("wmo-03462")
    assert :error = Stations.fetch("wmo-03772")
    assert Stations.all() == [Stations.primary(), Stations.backup()]

    for station <- Stations.all(),
        do: assert(Map.keys(station) |> Enum.sort() == [:geohash, :id, :name, :verified_on, :wmo])
  end
end
