defmodule WallopWeb.Plugs.SelfCheckRateLimit do
  @moduledoc """
  Per-IP rate limit on the proof page's public self-check endpoint.

  The self-check is a flat-boolean lookup against the published winner
  list. Its only job is "is THIS UUID a winner — yes or no." Throttle
  concentrated probing per IP so that a client who holds a UUID (say,
  an entrant) can't cheaply enumerate outcome state on someone else's
  behalf by submitting many UUIDs in quick succession.

  Separate ETS table from the API `RateLimit` plug: the generic auth
  path uses 10/minute (appropriate for a bcrypt-gated API), which
  would block legitimate proof page viewers here. The self-check
  window allows 60 checks/minute per IP — plenty for a human pasting
  UUIDs, too little for scripted enumeration of a leaked list.

  Table: `:wallop_self_check_rate_limit` (named, public, set)
  Key:   `{:self_check, ip_string}`
  Value: `{key, count, window_start_monotonic_ms}`
  """

  import Plug.Conn

  @table :wallop_self_check_rate_limit
  @max_attempts 60
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    # Only enforce when the request actually carries a self-check
    # (either via path param or query string).
    if has_self_check?(conn) do
      ensure_table()
      ip = conn.remote_ip |> :inet.ntoa() |> List.to_string()

      case check_rate(ip) do
        :ok ->
          conn

        :rate_limited ->
          conn
          |> put_status(429)
          |> Phoenix.Controller.put_view(html: WallopWeb.ErrorHTML, json: WallopWeb.ErrorJSON)
          |> put_resp_content_type("text/plain")
          |> send_resp(429, "Too many self-check attempts. Try again in a minute.\n")
          |> halt()
      end
    else
      conn
    end
  end

  defp has_self_check?(conn) do
    entry_id_param = lookup_param(conn)
    is_binary(entry_id_param) and entry_id_param != ""
  end

  defp lookup_param(%Plug.Conn{params: %{"entry_id" => value}}) when is_binary(value), do: value

  defp lookup_param(%Plug.Conn{path_params: %{"entry_id" => value}}) when is_binary(value),
    do: value

  defp lookup_param(%Plug.Conn{query_params: %{"entry_id" => value}}) when is_binary(value),
    do: value

  defp lookup_param(_), do: nil

  @doc "Increments the counter for `ip`. Returns `:ok` or `:rate_limited`."
  def check_rate(ip) do
    key = {:self_check, ip}
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

  @doc "Deletes all entries from the rate limit table. Intended for tests."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Creates the ETS table if it does not already exist."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table])
      _tid -> :ok
    end
  end
end
