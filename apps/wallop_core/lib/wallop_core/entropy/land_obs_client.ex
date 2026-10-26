defmodule WallopCore.Entropy.LandObsClient do
  @moduledoc """
  Met Office DataHub Land Observations (`/observation-land/1/{geohash}`).

  Used only by observation-weather draws.
  The response body is kept byte-for-byte as `raw`. Numbers are read from
  their JSON text by `WallopCore.Weather.LandObsGrammar` (never as floats),
  and only the row for exactly the requested hour is used.

  Only the tag's one station (`WallopCore.Weather.Stations`) can be fetched.

  The HTTP request is deliberately narrow: https only, no redirects (a 3xx
  is an error), no retries (the caller's job decides when to try again),
  no compression, fixed timeouts and a cap on the body size. The API key
  goes only in the `apikey` request header, never in the URL, and never
  into a returned error.
  """

  alias WallopCore.Weather.{LandObsGrammar, Stations}

  @base_url "https://data.hub.api.metoffice.gov.uk/observation-land/1"
  @connect_timeout 5_000
  @receive_timeout 10_000
  # A full 48-hour response is about 10 KiB.
  @max_body_bytes 1_048_576

  @type observation :: %{value: String.t(), raw: binary(), observation_time: DateTime.t()}
  @type error ::
          :no_api_key
          | :invalid_api_key
          | :unknown_station
          | :not_an_hour
          | :insecure_url
          | :body_too_large
          | :invalid_json
          | :too_deep
          | :duplicate_key
          | :invalid_response
          | :missing_hour
          | :duplicate_hour
          | {:unexpected_status, integer()}
          | {:transport, atom()}
          | {:transport, :http_error}
          | LandObsGrammar.error_reason()

  @doc """
  Whether a usable Land Observations key is configured: set, non-empty and
  visible ASCII. It is the same check each request makes before it is sent.
  The node that runs the fetches records it for locks to read
  (`WallopCore.Weather.ObservationReadiness`), so what a lock is told and
  what the fetches do can't disagree.
  """
  @spec key_configured?() :: boolean()
  def key_configured?, do: match?({:ok, _}, api_key())

  @doc "The largest response body accepted, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc """
  Fetch the observation for `hour` (a whole UTC hour) at the station with
  `geohash`, as its canonical `weather_value`.
  """
  @spec fetch_hour(String.t(), DateTime.t()) :: {:ok, observation()} | {:error, error()}
  def fetch_hour(geohash, %DateTime{} = hour) when is_binary(geohash) do
    with :ok <- known_station(geohash),
         :ok <- whole_utc_hour(hour),
         {:ok, body} <- get("/" <> geohash),
         {:ok, rows} <- decode_rows(body),
         {:ok, row} <- row_for(rows, hour),
         {:ok, value} <- LandObsGrammar.canonical_value(row) do
      {:ok, %{value: value, raw: body, observation_time: hour}}
    end
  end

  defp known_station(geohash) do
    if Enum.any?(Stations.all(), &(&1.geohash == geohash)),
      do: :ok,
      else: {:error, :unknown_station}
  end

  defp whole_utc_hour(%DateTime{time_zone: "Etc/UTC", minute: 0, second: 0, microsecond: {0, _}}),
    do: :ok

  defp whole_utc_hour(_), do: {:error, :not_an_hour}

  defp decode_rows(body) do
    case LandObsGrammar.decode(body) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:ok, _} -> {:error, :invalid_response}
      {:error, :too_deep} -> {:error, :too_deep}
      {:error, :duplicate_key} -> {:error, :duplicate_key}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp row_for(rows, hour) do
    stamp = Calendar.strftime(hour, "%Y-%m-%dT%H:%M:%SZ")

    case Enum.filter(rows, &(is_map(&1) and Map.get(&1, "datetime") == stamp)) do
      [row] -> {:ok, row}
      [] -> {:error, :missing_hour}
      _ -> {:error, :duplicate_hour}
    end
  end

  defp get(path) do
    with {:ok, key} <- api_key(),
         {:ok, url} <- https_url(base_url() <> path) do
      opts = [
        headers: [{"apikey", key}, {"accept", "application/json"}],
        into: &collect_capped/2
      ]

      url
      |> Req.get(Keyword.merge(request_options(), opts))
      |> handle_response()
    end
  end

  defp handle_response({:ok, %Req.Response{private: %{body_too_large: true}}}),
    do: {:error, :body_too_large}

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) when is_binary(body),
    do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:unexpected_status, status}}

  # Only an atom reason from a transport error is passed on. Any other
  # reason (for example a Mint header error, which quotes the header value)
  # could carry the key, so it is replaced.
  defp handle_response({:error, %Req.TransportError{reason: reason}}) when is_atom(reason),
    do: {:error, {:transport, reason}}

  defp handle_response({:error, %Mint.TransportError{reason: reason}}) when is_atom(reason),
    do: {:error, {:transport, reason}}

  defp handle_response({:error, _}), do: {:error, {:transport, :http_error}}

  defp collect_capped({:data, data}, {req, resp}) do
    body = resp.body

    if byte_size(body) + byte_size(data) > @max_body_bytes do
      {:halt, {req, %{Req.Response.put_private(resp, :body_too_large, true) | body: ""}}}
    else
      {:cont, {req, %{resp | body: body <> data}}}
    end
  end

  defp api_key do
    case Application.get_env(:wallop_core, :met_office_obs_api_key) do
      nil ->
        {:error, :no_api_key}

      "" ->
        {:error, :no_api_key}

      key when is_binary(key) ->
        if visible_ascii?(key), do: {:ok, key}, else: {:error, :invalid_api_key}

      _ ->
        {:error, :invalid_api_key}
    end
  end

  # Visible ASCII only, so the key can never be refused (and quoted) by the
  # HTTP client as an invalid header value.
  defp visible_ascii?(key), do: Regex.match?(~r/\A[\x21-\x7E]+\z/, key)

  defp https_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, query: nil, userinfo: nil}
      when is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, :insecure_url}
    end
  end

  defp base_url, do: Keyword.get(config(), :base_url, @base_url)
  defp config, do: Application.get_env(:wallop_core, __MODULE__, [])

  @doc false
  # The effective Req options. Config may set only `:plug`,
  # `req_options: [receive_timeout: ...]` and
  # `req_options: [connect_options: [timeout: ...]]`; everything else is
  # fixed here.
  @spec request_options() :: keyword()
  def request_options do
    overrides = Keyword.get(config(), :req_options, [])
    connect = Keyword.get(overrides, :connect_options, [])

    [
      connect_options: [timeout: Keyword.get(connect, :timeout, @connect_timeout)],
      receive_timeout: Keyword.get(overrides, :receive_timeout, @receive_timeout),
      redirect: false,
      retry: false,
      compressed: false,
      decode_body: false
    ]
    |> put_plug(Keyword.get(config(), :plug))
  end

  defp put_plug(opts, nil), do: opts
  defp put_plug(opts, plug), do: Keyword.put(opts, :plug, plug)
end
