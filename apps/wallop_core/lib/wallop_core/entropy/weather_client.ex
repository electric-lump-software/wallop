defmodule WallopCore.Entropy.WeatherClient do
  @moduledoc """
  HTTP client for Met Office Land Observations API.

  Fetches mean sea level pressure from a declared weather station at a
  declared observation time. The pressure reading is normalized to an
  integer string using Decimal rounding (half-up).
  """

  @base_url "https://data.hub.api.metoffice.gov.uk/sitespecific/v0/point/hourly"
  @connect_timeout 5_000
  @receive_timeout 10_000

  @doc """
  Fetch the MSL pressure reading for a location at a specific time.

  `latitude` and `longitude` identify the location.
  `observation_time` is a DateTime for the target hour.

  Returns `{:ok, %{value: "1013", raw: response_text}}` or `{:error, reason}`.

  The value is normalized: the raw decimal pressure is rounded half-up to the
  nearest integer and returned as a string.
  """
  def fetch(latitude, longitude, observation_time) do
    api_key = Application.get_env(:wallop_core, :met_office_api_key)

    params = [
      latitude: latitude,
      longitude: longitude,
      includeLocationName: true,
      dataSource: "BD1"
    ]

    headers = [
      {"apikey", api_key},
      {"accept", "application/json"}
    ]

    case Req.get(base_url(), req_options(params: params, headers: headers)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_pressure(body, observation_time)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Normalize a pressure value to an integer string using Decimal half-up rounding.

  ## Examples

      iex> WallopCore.Entropy.WeatherClient.normalize_pressure(1013.4)
      "1013"

      iex> WallopCore.Entropy.WeatherClient.normalize_pressure(1013.5)
      "1014"
  """
  def normalize_pressure(value) when is_float(value) do
    # Convert float to string first to avoid floating-point precision issues.
    # Decimal.new/1 with a float can produce unexpected representations.
    value
    |> to_string()
    |> Decimal.new()
    |> normalize_pressure()
  end

  def normalize_pressure(value) when is_integer(value) do
    value
    |> Integer.to_string()
  end

  def normalize_pressure(%Decimal{} = value) do
    value
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
    |> Integer.to_string()
  end

  def normalize_pressure(value) when is_binary(value) do
    value
    |> Decimal.new()
    |> normalize_pressure()
  end

  defp parse_pressure(body, target_time) do
    raw = Jason.encode!(body)
    target_hour = DateTime.truncate(target_time, :second)

    # Met Office response structure: features[0].properties.timeSeries[]
    # Each entry has a "time" and "mslp" (mean sea level pressure)
    with {:ok, features} <- Map.fetch(body, "features"),
         [feature | _] <- features,
         {:ok, properties} <- Map.fetch(feature, "properties"),
         {:ok, time_series} <- Map.fetch(properties, "timeSeries") do
      case find_reading_for_hour(time_series, target_hour) do
        {:ok, pressure} ->
          {:ok, %{value: normalize_pressure(pressure), raw: raw}}

        :error ->
          {:error, :reading_not_found}
      end
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp find_reading_for_hour(time_series, target_hour) do
    target_str = Calendar.strftime(target_hour, "%Y-%m-%dT%H:00Z")

    Enum.find_value(time_series, :error, fn entry ->
      time = Map.get(entry, "time", "")
      mslp = Map.get(entry, "mslp")

      if String.starts_with?(time, String.slice(target_str, 0, 13)) and not is_nil(mslp) do
        {:ok, mslp}
      end
    end)
  end

  defp base_url do
    Application.get_env(:wallop_core, __MODULE__, [])
    |> Keyword.get(:base_url, @base_url)
  end

  defp req_options(extra) do
    base = [
      connect_options: [timeout: @connect_timeout],
      receive_timeout: @receive_timeout
    ]

    base =
      case Application.get_env(:wallop_core, __MODULE__, []) |> Keyword.get(:plug) do
        nil -> base
        plug -> Keyword.put(base, :plug, plug)
      end

    Keyword.merge(base, extra)
  end
end
