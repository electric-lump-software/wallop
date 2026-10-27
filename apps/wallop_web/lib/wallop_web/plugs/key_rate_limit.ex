defmodule WallopWeb.Plugs.KeyRateLimit do
  @moduledoc """
  Per-API-key limit. The limit is the key's
  `rate_limit_per_minute`, or 60 when unset. Runs after authentication.

  Signals `:near_limit` the first time a key reaches 80% of its limit in a
  minute, and `:limited` the first time it's refused in a minute (see
  `WallopWeb.RateLimitSignal`).
  """

  alias WallopWeb.RateLimiter
  alias WallopWeb.RateLimitResponse
  alias WallopWeb.RateLimitSignal

  @default_limit 60

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:api_key] do
      nil -> conn
      api_key -> enforce(conn, api_key, limit_for(api_key))
    end
  end

  @doc "The key's requests-per-minute limit: its own setting, or 60."
  @spec limit_for(map()) :: pos_integer()
  def limit_for(%{rate_limit_per_minute: n}) when is_integer(n), do: n
  def limit_for(_api_key), do: @default_limit

  @doc "The request count at which a key is near its limit: 80%, rounded up, at least 1."
  @spec near_threshold(pos_integer()) :: pos_integer()
  def near_threshold(limit), do: max(1, div(limit * 4 + 4, 5))

  defp enforce(conn, api_key, limit) do
    case RateLimiter.hit("key", api_key.id, limit) do
      {:allow, count} ->
        if count == near_threshold(limit),
          do: RateLimitSignal.emit(api_key.id, :near_limit, limit)

        conn

      {:deny, retry_after} ->
        if RateLimiter.first_this_window?("key-limited-event", api_key.id),
          do: RateLimitSignal.emit(api_key.id, :limited, limit)

        RateLimitResponse.send_429(
          conn,
          retry_after,
          "rate_limit_exceeded",
          "API key rate limit exceeded (#{limit} requests/minute). Retry after #{retry_after} seconds.",
          %{limit: limit}
        )
    end
  end
end
