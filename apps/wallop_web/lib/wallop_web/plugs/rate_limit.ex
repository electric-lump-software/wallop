defmodule WallopWeb.Plugs.RateLimit do
  @moduledoc """
  ETS-based per-IP rate limiting plug.

  Tracks the number of requests per IP address within a 60-second **fixed**
  window. Requests exceeding 10 attempts in a window are rejected with
  HTTP 429 before reaching the auth plug, preventing CPU exhaustion from
  bcrypt verification.

  The window is anchored at the first request from an IP and only resets
  once a request arrives after it has closed — it does not slide. Two
  consequences worth knowing: a caller may spend the whole budget in the
  first second and then wait out the remainder of the minute, and a caller
  timing requests around the boundary can land 20 in quick succession (10
  at the end of one window, 10 at the start of the next). Both are
  acceptable here: the cap exists to bound bcrypt work per IP, and 20
  verifications in a burst is still a trivial amount of CPU. It is not a
  defence against a distributed attack, which spreads across IPs and never
  meets this cap at all.

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

  @doc "Name of the backing ETS table. Used by the sweeper."
  def table, do: @table

  @doc "Length of the counting window in milliseconds. Used by the sweeper."
  def window_ms, do: @window_ms

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
