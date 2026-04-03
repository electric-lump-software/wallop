defmodule WallopCore.Entropy.DrandClient do
  @moduledoc """
  HTTP client for the drand randomness beacon.

  Fetches cryptographically verified random values from the League of Entropy
  (https://drand.love). Each round produces a unique, unpredictable random value
  that can be independently verified.
  """

  @base_url "https://api.drand.sh"
  @connect_timeout 5_000
  @receive_timeout 10_000

  @default_relays [
    "https://api.drand.sh",
    "https://drand.cloudflare.com",
    "https://api2.drand.sh",
    "https://api3.drand.sh"
  ]

  @quicknet_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"

  @doc "The chain hash for the quicknet chain (3-second rounds)."
  def quicknet_chain_hash, do: @quicknet_chain_hash

  @doc """
  Fetch a specific round, trying multiple relays on failure.

  Fails over on transport errors, timeouts, and 5xx responses.
  Does NOT failover on 404 (round not yet produced) or invalid responses.
  """
  def fetch_with_failover(chain_hash, round) when is_binary(chain_hash) and is_integer(round) do
    config = Application.get_env(:wallop_core, __MODULE__, [])
    relays = Keyword.get(config, :relays, @default_relays)

    try_relays(relays, chain_hash, round, [])
  end

  defp try_relays([], _chain_hash, _round, errors) do
    {:error, {:all_relays_failed, errors}}
  end

  defp try_relays([relay | rest], chain_hash, round, errors) do
    case fetch(chain_hash, round, relay) do
      {:ok, _} = success ->
        success

      {:error, :not_found} = not_found ->
        not_found

      {:error, :invalid_response} = invalid ->
        invalid

      {:error, reason} ->
        try_relays(rest, chain_hash, round, [{relay, reason} | errors])
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

    case Req.get(url, req_options()) do
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

    case Req.get(url, req_options()) do
      {:ok, %Req.Response{status: 200, body: %{"round" => round}}} when is_integer(round) ->
        {:ok, round}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
