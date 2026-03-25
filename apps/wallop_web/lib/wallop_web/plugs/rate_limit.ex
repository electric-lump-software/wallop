defmodule WallopWeb.Plugs.RateLimit do
  @moduledoc """
  ETS-based per-IP rate limiting plug.

  Tracks the number of requests per IP address within a 60-second sliding
  window. Requests exceeding 10 attempts in a window are rejected with
  HTTP 429 before reaching the auth plug, preventing CPU exhaustion from
  bcrypt verification.

  Table: `:wallop_rate_limit` (named, public, set)
  Key:   `{:rate, ip_string}`
  Value: `{key, count, window_start_monotonic_ms}`
  """

  import Plug.Conn

  @table :wallop_rate_limit
  @max_attempts 10
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    ensure_table()
    ip = conn.remote_ip |> :inet.ntoa() |> List.to_string()

    case check_rate(ip) do
      :ok ->
        conn

      :rate_limited ->
        conn
        |> put_status(429)
        |> Phoenix.Controller.json(%{errors: %{detail: "Too Many Requests"}})
        |> halt()
    end
  end

  @doc "Increments the counter for `ip`. Returns `:ok` or `:rate_limited`."
  def check_rate(ip) do
    key = {:rate, ip}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start < @window_ms ->
        if count >= @max_attempts do
          :rate_limited
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

  @doc "Creates the ETS table if it does not already exist."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table])

      _tid ->
        :ok
    end
  end
end
