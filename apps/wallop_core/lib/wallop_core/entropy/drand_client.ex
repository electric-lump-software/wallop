defmodule WallopCore.Entropy.DrandClient do
  @moduledoc """
  HTTP client for the drand randomness beacon.

  Fetches cryptographically verified random values from the League of Entropy
  (https://drand.love). Each round produces a unique, unpredictable random value
  that can be independently verified.

  Bodies are read through a size cap (`max_body_bytes/0`; a beacon is about
  200 bytes) and only uncompressed, so a relay can't make the node buffer
  an unbounded response.

  A body over the cap, or one that isn't a JSON object (an array, null, a
  CDN's HTML page), is `{:error, :malformed_body}`: a transient fault of
  the relay or the network in between, like a 5xx, so it fails over to the
  next relay and callers retry. `{:error, :invalid_response}` is kept for a
  JSON object that is the wrong beacon (wrong round, bad randomness).

  With `verify_bls: true` (observation-weather draws) the beacon must also
  be quicknet's own: its BLS signature is checked against quicknet's public
  key (`WallopCore.Drand.Bls`), so a relay can't forge a round. Forecast
  draws don't pass it yet and are checked as before.
  """

  require Logger

  alias WallopCore.Drand.{Bls, Quicknet}

  @base_url "https://api.drand.sh"
  @connect_timeout 5_000
  @receive_timeout 10_000
  @max_body_bytes 16_384
  # With `on_invalid: :next`, each relay gets this long in total, then the
  # next one is asked.
  @relay_deadline_ms 10_000

  @default_relays [
    "https://api.drand.sh",
    "https://drand.cloudflare.com",
    "https://api2.drand.sh",
    "https://api3.drand.sh"
  ]

  @quicknet_chain_hash "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"

  # Tests swap in a wrapper around the real check; see
  # WallopCore.Test.DrandBls. Fixed at compile time.
  @bls Application.compile_env(:wallop_core, [__MODULE__, :bls], Bls)

  if @bls != Bls and Mix.env() != :test do
    raise CompileError,
      description:
        "#{inspect(__MODULE__)}: :bls may be set only in the test environment (got " <>
          "#{inspect(@bls)} in #{Mix.env()}). Outside tests the client always uses " <>
          "WallopCore.Drand.Bls."
  end

  @doc "The chain hash for the quicknet chain (3-second rounds)."
  def quicknet_chain_hash, do: @quicknet_chain_hash

  @doc "The largest response body accepted, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc false
  # The total time one relay gets under `on_invalid: :next`. Configurable
  # (`relay_deadline_ms`) only so tests can shorten it.
  @spec relay_deadline_ms() :: pos_integer()
  def relay_deadline_ms do
    Application.get_env(:wallop_core, __MODULE__, [])
    |> Keyword.get(:relay_deadline_ms, @relay_deadline_ms)
  end

  @doc false
  @spec relays() :: [String.t()]
  def relays,
    do: Application.get_env(:wallop_core, __MODULE__, []) |> Keyword.get(:relays, @default_relays)

  @doc """
  Fetch a specific round, trying multiple relays on failure.

  Fails over on transport errors, timeouts, 5xx responses and malformed
  bodies (`:malformed_body`).
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

      `:next` also bounds each relay: no Req retries (failover is the
      retry, so a `Retry-After` never makes it sleep), and a total
      deadline per relay (`relay_deadline_ms/0`, 10 s), after which that
      relay's error is `:relay_timeout` and the next one is asked. A fetch
      that raises or exits still raises or exits here, as under `:stop`.

    * `:verify_bls` - `false` (the default) or `true`. With `true` a beacon
      is accepted only if the chain asked for is quicknet, the signature is
      96 lowercase hex characters, the round is the one asked for (and in
      1..2^64-1), the signature verifies under quicknet's public key, and
      the randomness is sha256 of the signature. Any failure is that relay's
      `{:error, :invalid_response}`, logged with the relay and the kind of
      failure. Observation-weather draws pass `true`.
  """
  def fetch_with_failover(chain_hash, round, opts \\ [])
      when is_binary(chain_hash) and is_integer(round) do
    on_invalid = Keyword.get(opts, :on_invalid, :stop)
    verify_bls? = Keyword.get(opts, :verify_bls, false) == true

    try_relays(relays(), chain_hash, round, {on_invalid, verify_bls?}, [])
  end

  defp try_relays([], _chain_hash, _round, {:next, _verify}, [_ | _] = errors) do
    if Enum.all?(errors, &match?({_relay, :not_found}, &1)),
      do: {:error, :not_found},
      else: {:error, {:all_relays_failed, errors}}
  end

  defp try_relays([], _chain_hash, _round, _on_invalid, errors) do
    {:error, {:all_relays_failed, errors}}
  end

  defp try_relays([relay | rest], chain_hash, round, {mode, verify?} = on_invalid, errors) do
    case fetch_relay(chain_hash, round, relay, mode, verify?) do
      {:ok, _} = success ->
        success

      # One relay's refusal (lagging, broken or hostile) is not the round's.
      {:error, reason} when mode == :next ->
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

  defp fetch_relay(chain_hash, round, relay, :next, verify?),
    do: bounded_fetch(chain_hash, round, relay, verify?)

  defp fetch_relay(chain_hash, round, relay, _on_invalid, verify?),
    do: do_fetch(chain_hash, round, relay, verify_bls: verify?)

  # One relay, no Req retries, within the relay deadline. The request runs
  # in a task so a relay dripping bytes can be abandoned; a raise, exit or
  # throw inside it is passed on to the caller unchanged.
  defp bounded_fetch(chain_hash, round, relay, verify?) do
    task =
      Task.async(fn ->
        try do
          {:done, do_fetch(chain_hash, round, relay, retry: false, verify_bls: verify?)}
        rescue
          e -> {:raised, e, __STACKTRACE__}
        catch
          kind, reason -> {kind, reason}
        end
      end)

    case Task.yield(task, relay_deadline_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:done, result}} -> result
      {:ok, {:raised, e, stacktrace}} -> reraise e, stacktrace
      {:ok, {:exit, reason}} -> exit(reason)
      {:ok, {:throw, value}} -> throw(value)
      nil -> {:error, :relay_timeout}
    end
  end

  @doc """
  Fetch a specific round from a drand chain.

  Returns `{:ok, %{randomness: hex, signature: hex, round: integer, response: text}}`
  or `{:error, reason}`.
  """
  def fetch(chain_hash, round, relay_url \\ nil)
      when is_binary(chain_hash) and is_integer(round),
      do: do_fetch(chain_hash, round, relay_url, [])

  defp do_fetch(chain_hash, round, relay_url, extra_opts) do
    base = relay_url || base_url()
    url = "#{base}/#{chain_hash}/public/#{round}"
    {verify?, extra_opts} = Keyword.pop(extra_opts, :verify_bls, false)

    case get(url, extra_opts) do
      {:ok, %Req.Response{private: %{body_too_large: true}}} ->
        {:error, :malformed_body}

      {:ok, %Req.Response{status: 200, body: body}} ->
        with {:ok, beacon} <- parse_and_validate(body, chain_hash, round),
             :ok <- check_bls(verify?, beacon, chain_hash, round, base),
             do: {:ok, beacon}

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
        {:error, :malformed_body}

      {:ok, %Req.Response{status: 200, body: %{"round" => round}}} when is_integer(round) ->
        {:ok, round}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Anything but a JSON object (an array, a string, null, a non-JSON page)
  # is malformed, never a crash.
  defp parse_and_validate(body, _chain_hash, _expected_round) when not is_map(body),
    do: {:error, :malformed_body}

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

  defp check_bls(false, _beacon, _chain_hash, _round, _relay), do: :ok

  defp check_bls(true, beacon, chain_hash, round, relay) do
    case bls_failure(beacon, chain_hash, round) do
      nil ->
        :ok

      kind ->
        Logger.warning(
          "DrandClient: relay #{relay} sent a beacon that failed the BLS check: #{kind}"
        )

        {:error, :invalid_response}
    end
  end

  # The first check the beacon fails, or nil. The format checks run first,
  # so the NIF only ever sees a well-formed signature and round.
  defp bls_failure(beacon, chain_hash, round) do
    cond do
      chain_hash != Quicknet.chain_hash() -> :wrong_chain
      not (beacon.signature =~ ~r/\A[0-9a-f]{96}\z/) -> :signature_format
      not (beacon.round == round and round in 1..Bls.max_round()//1) -> :round
      not @bls.verify_quicknet(beacon.round, beacon.signature) -> :bad_signature
      beacon.randomness != randomness_of(beacon.signature) -> :randomness_mismatch
      true -> nil
    end
  end

  defp randomness_of(signature_hex) do
    sig = Base.decode16!(signature_hex, case: :lower)
    :sha256 |> :crypto.hash(sig) |> Base.encode16(case: :lower)
  end

  # The body is collected through the cap; Req then decodes JSON by content
  # type as before. Compression stays off (Req's default), so a body sent
  # compressed anyway is never inflated: Req leaves it encoded, which isn't
  # a map, which is refused.
  defp get(url, extra_opts \\ []) do
    opts = Keyword.merge([into: &collect_capped/2, compressed: false], extra_opts)
    Req.get(url, Keyword.merge(req_options(), opts))
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
