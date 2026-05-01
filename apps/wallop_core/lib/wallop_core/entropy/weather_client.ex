defmodule WallopCore.Entropy.WeatherClient do
  @moduledoc """
  HTTP client for Met Office Land Observations API.

  Fetches the latest mean sea level pressure observation from a declared
  weather station. The entry with the most recent timestamp in the time
  series is selected. The raw mslp value (integer, in Pascals) is
  returned as a string.
  """

  @base_url "https://data.hub.api.metoffice.gov.uk/sitespecific/v0/point/hourly"
  @connect_timeout 5_000
  @receive_timeout 10_000

  @doc """
  Fetch the MSL pressure reading for a location at a specific target time.

  `latitude` and `longitude` identify the location. `target_time` is the
  declared weather observation time from the draw — the reading closest to
  (but not after) this time is selected. This pins the observation to the
  declared hour, preventing drift across retries.

  Returns `{:ok, %{value: "102340", observation_time: ~U[...], raw: response_text}}`
  or `{:error, reason}`.

  The value is the raw mslp integer from the Met Office API (Pascals),
  returned as a string.
  """
  def fetch(latitude, longitude, target_time \\ nil) do
    api_key = require_api_key!()

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
        parse_pressure(body, target_time)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pressure_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp pressure_to_string(value) when is_float(value), do: value |> round() |> Integer.to_string()

  defp parse_pressure(body, target_time) do
    raw = Jason.encode!(body)

    # Met Office response structure: features[0].properties.timeSeries[]
    # Each entry has a "time" and "mslp" (mean sea level pressure)
    with {:ok, features} <- Map.fetch(body, "features"),
         [feature | _] <- features,
         {:ok, properties} <- Map.fetch(feature, "properties"),
         {:ok, time_series} <- Map.fetch(properties, "timeSeries") do
      case find_reading(time_series, target_time) do
        {:ok, pressure, observation_time} ->
          {:ok,
           %{value: pressure_to_string(pressure), observation_time: observation_time, raw: raw}}

        :error ->
          {:error, :no_readings_available}
      end
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp find_reading(time_series, nil) do
    # No target time — use latest reading (backwards compat for tests)
    find_latest_reading(time_series)
  end

  defp find_reading(time_series, %DateTime{} = target_time) do
    # Find the reading closest to target_time (at or before it, within 1 hour)
    time_series
    |> Enum.filter(&Map.has_key?(&1, "mslp"))
    |> Enum.flat_map(&parse_entry_time/1)
    |> Enum.filter(fn {dt, _} -> DateTime.compare(dt, target_time) != :gt end)
    |> Enum.max_by(fn {dt, _} -> DateTime.to_unix(dt) end, fn -> nil end)
    |> case do
      nil ->
        :error

      {observation_time, entry} ->
        # Reject if more than 1 hour before target
        diff = DateTime.diff(target_time, observation_time, :second)

        if diff <= 3600 do
          {:ok, entry["mslp"], observation_time}
        else
          :error
        end
    end
  end

  defp find_latest_reading(time_series) do
    time_series
    |> Enum.filter(&Map.has_key?(&1, "mslp"))
    |> Enum.flat_map(&parse_entry_time/1)
    |> Enum.max_by(fn {dt, _} -> DateTime.to_unix(dt) end, fn -> nil end)
    |> case do
      nil -> :error
      {observation_time, entry} -> {:ok, entry["mslp"], observation_time}
    end
  end

  defp parse_entry_time(%{"time" => time} = entry) when is_binary(time) do
    case parse_met_office_time(time) do
      {:ok, dt} -> [{dt, entry}]
      _ -> []
    end
  end

  defp parse_entry_time(_), do: []

  # Met Office timestamps omit seconds (e.g. "2025-01-15T13:00Z").
  # Normalise to full ISO 8601 before parsing.
  defp parse_met_office_time(time_str) do
    normalised = Regex.replace(~r/T(\d{2}:\d{2})Z$/, time_str, "T\\1:00Z")

    case DateTime.from_iso8601(normalised) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp base_url do
    Application.get_env(:wallop_core, __MODULE__, [])
    |> Keyword.get(:base_url, @base_url)
  end

  # `runtime.exs` raises if `MET_OFFICE_API_KEY` is unset in prod, but this
  # function is the only consumer at runtime and can defend itself against
  # a misconfigured release that boots without the application config
  # provider applying. Without the guard, a nil `apikey` header silently
  # 401s and the entropy worker falls back to drand-only — a degraded
  # mode that is easy to miss in observability.
  defp require_api_key! do
    case Application.get_env(:wallop_core, :met_office_api_key) do
      key when is_binary(key) and byte_size(key) > 0 ->
        key

      _ ->
        raise "MET_OFFICE_API_KEY is not configured. Refusing to call the Met Office API with a nil key."
    end
  end

  defp req_options(extra) do
    base = [
      connect_options: [timeout: @connect_timeout],
      receive_timeout: @receive_timeout
    ]

    config = Application.get_env(:wallop_core, __MODULE__, [])

    base =
      case Keyword.get(config, :plug) do
        nil -> base
        plug -> Keyword.put(base, :plug, plug)
      end

    overrides = Keyword.get(config, :req_options, [])

    base
    |> Keyword.merge(overrides)
    |> Keyword.merge(extra)
  end
end
