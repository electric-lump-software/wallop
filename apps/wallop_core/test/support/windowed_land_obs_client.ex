defmodule WallopCore.Test.WindowedLandObsClient do
  @moduledoc """
  The Land Observations client `WeatherObservationWorker` uses in tests
  (set in `config/test.exs`).

  The database clock can't be set from a test, so tests place "now" in a
  fetch window by giving draws a `weather_time` that isn't a whole hour, as
  the observation store tests do. The real client accepts only whole hours,
  so this fetches the whole hour at or before `weather_time` with the real
  client (request, HTTP stub, parsing, row selection, grammar) and stamps the
  reading with the `weather_time` asked for. For a whole hour it is exactly
  the real client.
  """

  alias WallopCore.Entropy.LandObsClient

  @spec fetch_hour(String.t(), DateTime.t()) ::
          {:ok, LandObsClient.observation()} | {:error, LandObsClient.error()}
  def fetch_hour(geohash, %DateTime{} = weather_time) do
    case LandObsClient.fetch_hour(geohash, floor_hour(weather_time)) do
      {:ok, reading} -> {:ok, %{reading | observation_time: weather_time}}
      error -> error
    end
  end

  @doc "The whole UTC hour at or before `t`."
  @spec floor_hour(DateTime.t()) :: DateTime.t()
  def floor_hour(%DateTime{} = t) do
    s = DateTime.to_unix(t)
    DateTime.from_unix!(s - Integer.mod(s, 3600))
  end
end
