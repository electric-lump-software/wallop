defmodule WallopWeb.Plugs.SelfCheckRateLimit do
  @moduledoc """
  Per-IP rate limit on the proof page's public self-check endpoint.

  The self-check is a flat-boolean lookup against the published winner
  list. Its only job is "is THIS UUID a winner — yes or no." Throttle
  concentrated probing per IP so that a client who holds a UUID (say,
  an entrant) can't cheaply enumerate outcome state on someone else's
  behalf by submitting many UUIDs in quick succession.

  Separate bucket from the API limits: the generic auth path is
  tighter (appropriate for a bcrypt-gated API), which would block
  legitimate proof page viewers here. The self-check allows 60
  checks/minute per IP — plenty for a human pasting UUIDs, too little
  for scripted enumeration of a leaked list.

  The live proof page calls `check_rate/1` too, so the HTTP and
  LiveView budgets are one. Counts through `WallopWeb.RateLimiter`
  (ADR-0015).
  """

  import Plug.Conn

  alias WallopWeb.RateLimiter

  @max_attempts 60

  def init(opts), do: opts

  def call(conn, _opts) do
    # Only enforce when the request actually carries a self-check
    # (either via path param or query string).
    if has_self_check?(conn) do
      ip = conn.remote_ip |> :inet.ntoa() |> List.to_string()

      case RateLimiter.hit("self-check", ip, @max_attempts) do
        {:allow, _} ->
          conn

        {:deny, retry_after} ->
          conn
          |> put_status(429)
          |> Phoenix.Controller.put_view(html: WallopWeb.ErrorHTML, json: WallopWeb.ErrorJSON)
          |> put_resp_header("retry-after", Integer.to_string(retry_after))
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

  @doc """
  Counts a self-check for `ip`. Returns `:ok` or `:rate_limited`. Shared by
  the HTTP plug and the live proof page so they draw on one budget.
  """
  @spec check_rate(String.t()) :: :ok | :rate_limited
  def check_rate(ip) do
    case RateLimiter.hit("self-check", ip, @max_attempts) do
      {:allow, _} -> :ok
      {:deny, _} -> :rate_limited
    end
  end

  @doc "Maximum self-checks per window per IP. Public for tests."
  def max_attempts, do: @max_attempts
end
