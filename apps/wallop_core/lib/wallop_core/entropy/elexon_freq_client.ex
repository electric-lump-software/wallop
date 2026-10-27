defmodule WallopCore.Entropy.ElexonFreqClient do
  @moduledoc """
  Elexon Insights `FREQ` (GB grid frequency, every 15 seconds), for
  grid-frequency draws only.

  One request per window: the 8 readings from T to T + 105 s. The response
  body is kept byte for byte as `raw`. Numbers are read from their JSON
  text by `WallopCore.Frequency.FreqGrammar` (never as floats), and only
  rows whose `measurementTime` is exactly one of the window's instants are
  used.

  The HTTP request is deliberately narrow: https only, no redirects (a 3xx
  is an error), no retries (the caller's job decides when to try again),
  no compression, fixed timeouts and a cap on the body size (checked while
  the body streams in). The JSON nesting depth is capped by the decoder.
  There is no key; if one is ever needed it goes in a header, never the
  URL, and only after the same visible-ASCII check as `LandObsClient`.
  """

  alias WallopCore.Frequency.{FreqGrammar, Schedule}

  @base_url "https://data.elexon.co.uk/bmrs/api/v1/datasets/FREQ"
  @connect_timeout 5_000
  @receive_timeout 10_000
  @max_body_bytes 262_144

  @type window :: %{value: String.t(), raw: binary(), freq_start: DateTime.t()}
  @type error ::
          :not_a_window_start
          | :insecure_url
          | :body_too_large
          | :invalid_json
          | :too_deep
          | :duplicate_key
          | :invalid_response
          | {:unexpected_status, integer()}
          | {:transport, atom()}
          | {:transport, :http_error}
          | FreqGrammar.window_error()

  @doc "The largest response body accepted, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc """
  Fetch the window starting at `freq_start` (UTC, whole seconds, on the
  15-second grid) as its canonical `freq_value`.
  """
  @spec fetch_window(DateTime.t()) :: {:ok, window()} | {:error, error()}
  def fetch_window(%DateTime{} = freq_start) do
    with :ok <- window_start(freq_start),
         {:ok, body} <- get(freq_start, Schedule.store_from(freq_start)),
         {:ok, rows} <- decode_rows(body),
         {:ok, value} <- FreqGrammar.window_from_rows(rows, freq_start) do
      {:ok, %{value: value, raw: body, freq_start: freq_start}}
    end
  end

  defp window_start(%DateTime{time_zone: "Etc/UTC", microsecond: {0, _}} = t) do
    if Integer.mod(DateTime.to_unix(t), Schedule.spacing_seconds()) == 0,
      do: :ok,
      else: {:error, :not_a_window_start}
  end

  defp window_start(_), do: {:error, :not_a_window_start}

  defp decode_rows(body) do
    case FreqGrammar.decode(body) do
      {:ok, %{"data" => rows}} when is_list(rows) -> {:ok, rows}
      {:ok, _} -> {:error, :invalid_response}
      {:error, :too_deep} -> {:error, :too_deep}
      {:error, :duplicate_key} -> {:error, :duplicate_key}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp get(from, to) do
    with {:ok, url} <- https_url(base_url()) do
      opts = [
        params: [
          measurementDateTimeFrom: stamp(from),
          measurementDateTimeTo: stamp(to),
          format: "json"
        ],
        headers: [{"accept", "application/json"}],
        into: &collect_capped/2
      ]

      url
      |> Req.get(Keyword.merge(request_options(), opts))
      |> handle_response()
    end
  end

  defp stamp(dt), do: Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%SZ")

  defp handle_response({:ok, %Req.Response{private: %{body_too_large: true}}}),
    do: {:error, :body_too_large}

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) when is_binary(body),
    do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:unexpected_status, status}}

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

  defp https_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, query: nil, userinfo: nil}
      when is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, :insecure_url}
    end
  end

  defp https_url(_), do: {:error, :insecure_url}

  defp base_url, do: Keyword.get(config(), :base_url, @base_url)
  defp config, do: Application.get_env(:wallop_core, __MODULE__, [])

  @doc false
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
