defmodule WallopWeb.RateLimiter do
  @moduledoc """
  The one rate limiter.

  Fixed one-minute windows aligned to the clock, via Hammer. The backend is
  configuration: ETS (default, exact on one node) or Redis (shared across
  nodes; windows follow each node's clock, so clock skew shifts window
  edges by the skew).

  If the store errors, the request is allowed (fail open):
  the error is logged at most once a minute per node and
  `[:wallop_web, :rate_limiter, :backend_error]` is emitted. A Redis call that
  takes longer than 100 ms counts as a store error, so a hung Redis costs a
  request at most that long. ETS calls are in-process and have no timeout.

  Keys are strings (`"bucket:id"`) because the Redis backend needs them.
  """

  require Logger

  @window_ms 60_000
  @log_throttle_key {__MODULE__, :last_error_log}

  defmodule Ets do
    @moduledoc false
    use Hammer, backend: :ets, algorithm: :fix_window
  end

  defmodule Redis do
    @moduledoc false
    use Hammer,
      backend: Hammer.Redis,
      algorithm: :fix_window,
      prefix: "wallop:rate:",
      timeout: 100
  end

  @type decision :: {:allow, non_neg_integer()} | {:deny, 1..60}

  @doc """
  Counts a hit on `bucket:id` and says whether it fits in `limit` for this
  window. A deny carries the `Retry-After` value in seconds. A store error
  allows the request.
  """
  @spec hit(String.t(), term(), pos_integer(), :ets | :redis) :: decision()
  def hit(bucket, id, limit, backend \\ backend()) do
    case safely(backend, bucket, fn -> module(backend).hit(key(bucket, id), @window_ms, limit) end) do
      {:allow, count} -> {:allow, count}
      {:deny, ms} -> {:deny, retry_after_seconds(ms)}
      :store_error -> {:allow, 0}
    end
  end

  @doc """
  True the first time `bucket:id` is seen this window; false after, and false
  when the store errors (so a failing store never triggers the once-a-window
  action on every request).
  """
  @spec first_this_window?(String.t(), term(), :ets | :redis) :: boolean()
  def first_this_window?(bucket, id, backend \\ backend()),
    do: match?({:allow, 1}, hit(bucket, id, 1, backend))

  @spec retry_after_seconds(non_neg_integer()) :: 1..60
  def retry_after_seconds(ms),
    do: ms |> Kernel./(1000) |> Float.ceil() |> trunc() |> max(1) |> min(60)

  @doc """
  The bucket id for a client address, used by every per-IP limiter so one
  client draws on one budget whichever door it comes through. IPv4 is the
  dotted address; IPv4-mapped IPv6 is the IPv4 client; other IPv6 is its /64,
  since one host usually holds a whole /64.
  """
  @spec ip_bucket(:inet.ip_address()) :: String.t()
  def ip_bucket({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> List.to_string()

  def ip_bucket({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do:
      ip_bucket(
        {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
      )

  def ip_bucket({a, b, c, d, _, _, _, _}),
    do: ({a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> List.to_string()) <> "/64"

  @doc "Clears every ETS counter. For tests."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(Ets) != :undefined, do: :ets.delete_all_objects(Ets)
    :ok
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    config = Keyword.merge(Application.get_env(:wallop_web, __MODULE__, []), opts)

    case Keyword.get(config, :backend, :ets) do
      :ets ->
        Ets.child_spec(clean_period: :timer.minutes(1))

      :redis ->
        url =
          Keyword.get(config, :redis_url) ||
            raise ArgumentError, "RATE_LIMIT_BACKEND=redis needs REDIS_URL"

        Redis.child_spec(url: url)
    end
  end

  defp safely(backend, bucket, fun) do
    fun.()
  rescue
    error -> store_error(backend, bucket, error)
  catch
    :exit, reason -> store_error(backend, bucket, reason)
  end

  defp store_error(backend, bucket, reason) do
    :telemetry.execute([:wallop_web, :rate_limiter, :backend_error], %{count: 1}, %{
      backend: backend,
      bucket: bucket
    })

    now = System.monotonic_time(:millisecond)

    if now - :persistent_term.get(@log_throttle_key, now - @window_ms) >= @window_ms do
      :persistent_term.put(@log_throttle_key, now)
      Logger.error("RateLimiter: #{backend} store error, allowing requests: #{inspect(reason)}")
    end

    :store_error
  end

  defp backend,
    do: Application.get_env(:wallop_web, __MODULE__, []) |> Keyword.get(:backend, :ets)

  defp module(:ets), do: Ets
  defp module(:redis), do: Redis

  defp key(bucket, id), do: "#{bucket}:#{id}"
end
