defmodule WallopWeb.Plugs.KeyRateLimit do
  @moduledoc """
  Per-API-key rate limit plug.

  Tracks the number of requests per API key within a 60-second sliding
  window. Requests exceeding the limit are rejected with HTTP 429 plus a
  `Retry-After` header.

  Runs after `WallopWeb.Plugs.ApiKeyAuth` so the actor is available.
  Per-IP rate limiting (in `WallopWeb.Plugs.RateLimit`) runs before auth
  to protect bcrypt CPU.

  Table: `:wallop_key_rate_limit` (named, public, set)
  Key:   `{:rate, api_key_id}`
  Value: `{key, count, window_start_monotonic_ms}`
  """

  import Plug.Conn

  @table :wallop_key_rate_limit
  @max_requests 60
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:api_key] do
      nil ->
        conn

      api_key ->
        ensure_table()

        case check_rate(api_key.id) do
          :ok ->
            conn

          {:rate_limited, retry_after_seconds} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
            |> put_status(429)
            |> Phoenix.Controller.json(%{
              errors: [
                %{
                  status: "429",
                  code: "rate_limit_exceeded",
                  title: "Too many requests",
                  detail:
                    "API key rate limit exceeded (#{@max_requests} requests/minute). " <>
                      "Retry after #{retry_after_seconds} seconds."
                }
              ]
            })
            |> halt()
        end
    end
  end

  @doc "Increments the counter for `api_key_id`. Returns `:ok` or `{:rate_limited, seconds}`."
  def check_rate(api_key_id) do
    key = {:rate, api_key_id}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start < @window_ms ->
        if count >= @max_requests do
          retry_after = max(1, div(@window_ms - (now - window_start), 1000))
          {:rate_limited, retry_after}
        else
          :ets.insert(@table, {key, count + 1, window_start})
          :ok
        end

      _ ->
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  end

  @doc "Deletes all entries from the rate limit table. Intended for use in tests."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table])

      _tid ->
        :ok
    end
  end
end
