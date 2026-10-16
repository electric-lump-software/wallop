defmodule WallopCore.Entropy.DrandClient do
  @moduledoc """
  HTTP client for the drand randomness beacon.

  Fetches cryptographically verified random values from the League of Entropy
  (https://drand.love). Each round produces a unique, unpredictable random value
  that can be independently verified.

  Bodies are read through a size cap (`max_body_bytes/0`; a beacon is about
  200 bytes) and only uncompressed, so a relay can't make the node buffer
  an unbounded response. A body over the cap, or one that isn't a JSON
  object, is `{:error, :invalid_response}`.
  """

  @base_url "https://api.drand.sh"
  @connect_timeout 5_000
  @receive_timeout 10_000
  @max_body_bytes 16_384

  @default_relays [
    "https://api.drand.sh",
    "https://drand.cloudflare.com",
    "https://api2.drand.sh",
    "https://api3.drand.sh"
  ]

  @quicknet_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"

  @doc "The chain hash for the quicknet chain (3-second rounds)."
  def quicknet_chain_hash, do: @quicknet_chain_hash

  @doc "The largest response body accepted, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc """
  Fetch a specific round, trying multiple relays on failure.

  Fails over on transport errors, timeouts, and 5xx responses.
  By default does NOT fail over on 404 (round not yet produced), 401/403,
  or invalid responses.

  Options:

    * `:on_invalid` - `:stop` (the default) returns the first relay's
      `{:error, :invalid_response}`, `{:error, :not_found}` or 401/403.
      `:next` tries the next relay on any of these, so one bad or lagging
      relay can't end the fetch. With `:next`, `{:error, :not_found}` comes
      back only when every relay said not found; any other mix of failures
      is `{:error, {:all_relays_failed, errors}}`. Observation-weather
      draws use `:next`.
  """
  def fetch_with_failover(chain_hash, round, opts \\ [])
      when is_binary(chain_hash) and is_integer(round) do
    config = Application.get_env(:wallop_core, __MODULE__, [])
    relays = Keyword.get(config, :relays, @default_relays)
    on_invalid = Keyword.get(opts, :on_invalid, :stop)

    try_relays(relays, chain_hash, round, on_invalid, [])
  end

  defp try_relays([], _chain_hash, _round, :next, [_ | _] = errors) do
    if Enum.all?(errors, &match?({_relay, :not_found}, &1)),
      do: {:error, :not_found},
      else: {:error, {:all_relays_failed, errors}}
  end

  defp try_relays([], _chain_hash, _round, _on_invalid, errors) do
    {:error, {:all_relays_failed, errors}}
  end

  defp try_relays([relay | rest], chain_hash, round, on_invalid, errors) do
    case fetch(chain_hash, round, relay) do
      {:ok, _} = success ->
        success

      # One relay's refusal (lagging, broken or hostile) is not the round's.
      {:error, reason} when on_invalid == :next ->
        try_relays(rest, chain_hash, round, on_invalid, [{relay, reason} | errors])

      {:error, :not_found} = not_found ->
        not_found

      {:error, :invalid_response} = invalid ->
        invalid

      # Don't failover on auth errors — all relays use the same credentials
      {:error, {:unexpected_status, status}} = auth_err when status in [401, 403] ->
        auth_err

      {:error, reason} ->
        try_relays(rest, chain_hash, round, on_invalid, [{relay, reason} | errors])
    end
  end

  @doc """
  Fetch a specific round from a drand chain.

  Returns `{:ok, %{randomness: hex, signature: hex, round: integer, response: text}}`
  or `{:error, reason}`.
  """
  def fetch(chain_hash, round, relay_url \\ nil)
      when is_binary(chain_hash) and is_integer(round) do
    base = relay_url || base_url()
    url = "#{base}/#{chain_hash}/public/#{round}"

    case get(url) do
      {:ok, %Req.Response{private: %{body_too_large: true}}} ->
        {:error, :invalid_response}

      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_and_validate(body, chain_hash, round)

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetch the latest round from a drand chain.

  Returns `{:ok, round_number}` or `{:error, reason}`.
  """
  def current_round(chain_hash) when is_binary(chain_hash) do
    url = "#{base_url()}/#{chain_hash}/public/latest"

    case get(url) do
      {:ok, %Req.Response{private: %{body_too_large: true}}} ->
        {:error, :invalid_response}

      {:ok, %Req.Response{status: 200, body: %{"round" => round}}} when is_integer(round) ->
        {:ok, round}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Anything but a JSON object (an array, a string, null, a non-JSON page)
  # is invalid, never a crash.
  defp parse_and_validate(body, _chain_hash, _expected_round) when not is_map(body),
    do: {:error, :invalid_response}

  defp parse_and_validate(body, _chain_hash, expected_round) do
    with {:ok, randomness} <- Map.fetch(body, "randomness"),
         {:ok, signature} <- Map.fetch(body, "signature"),
         {:ok, round} <- Map.fetch(body, "round"),
         true <- is_binary(randomness) and String.match?(randomness, ~r/^[0-9a-f]{64}$/),
         true <- is_binary(signature),
         true <- is_integer(round) and round == expected_round do
      response_text = Jason.encode!(body)

      {:ok,
       %{
         randomness: randomness,
         signature: signature,
         round: round,
         response: response_text
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  # The body is collected through the cap; Req then decodes JSON by content
  # type as before. Compression stays off (Req's default), so a body sent
  # compressed anyway is never inflated: Req leaves it encoded, which isn't
  # a map, which is refused.
  defp get(url) do
    Req.get(url, Keyword.merge(req_options(), into: &collect_capped/2, compressed: false))
  end

  defp collect_capped({:data, data}, {req, resp}) do
    body = resp.body

    if byte_size(body) + byte_size(data) > @max_body_bytes do
      {:halt, {req, %{Req.Response.put_private(resp, :body_too_large, true) | body: ""}}}
    else
      {:cont, {req, %{resp | body: body <> data}}}
    end
  end

  defp base_url do
    Application.get_env(:wallop_core, __MODULE__, [])
    |> Keyword.get(:base_url, @base_url)
  end

  defp req_options do
    base = [
      connect_options: [timeout: @connect_timeout],
      receive_timeout: @receive_timeout
    ]

    overrides =
      Application.get_env(:wallop_core, __MODULE__, [])
      |> Keyword.get(:req_options, [])

    Keyword.merge(base, overrides)
  end
end
