defmodule WallopWeb.RateLimiter do
  @moduledoc """
  The one rate limiter (ADR-0015).

  Fixed one-minute windows aligned to the clock, via Hammer. The backend is
  configuration: ETS (default, exact on one node) or Redis (shared across
  nodes; windows follow each node's clock, so clock skew shifts window
  edges by the skew).

  If the store errors, the request is allowed (ADR-0015, "Store failure"):
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
    # `timeout` is handed to Redix for every command; on expiry the call exits
    # and Redix discards the late reply, so nothing is left in our mailbox.
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

  @spec retry_after_seconds(non_neg_integer()) :: 1..60
  def retry_after_seconds(ms),
    do: ms |> Kernel./(1000) |> Float.ceil() |> trunc() |> max(1) |> min(60)

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
