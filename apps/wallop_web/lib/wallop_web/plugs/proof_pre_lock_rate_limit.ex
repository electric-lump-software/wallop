defmodule WallopWeb.Plugs.ProofPreLockRateLimit do
  @moduledoc """
  Per-IP rate limit on public proof-page reads of draws in `:open`
  status.

  Distinct from `WallopWeb.Plugs.SelfCheckRateLimit`:

  - **SelfCheckRateLimit** throttles entry-self-check probes (`?entry_id=...`)
    against the published winner list. It only fires when an `entry_id`
    is in scope, and caps how much server capacity one client can use
    on lookups.

  - **ProofPreLockRateLimit** (this plug) throttles plain proof-page
    GETs on draws in `:open` status. The pre-lock public surface is
    operationally noisy — entry counts and timestamps tick — and a
    bot that pinned the URL could enumerate operator activity. The
    bucket is separate so the two budgets don't fight: a viewer
    legitimately checking their entry on a completed draw should not
    be throttled by traffic on a different draw still being filled.

  Distinct bucket from SelfCheckRateLimit, with its own per-IP cap.
  Counts through `WallopWeb.RateLimiter`.

  ## Caps

  120 reads per IP per minute. Each read is a static-ish HTML page
  with a small JSON entry-count probe; a human watching a draw fill
  in real time sees ~60 polls per minute via LiveView. The cap leaves
  headroom for that and a second tab; it bites at sustained scripted
  enumeration.

  Only fires when the request URL targets a draw in `:open` status.
  Other statuses (terminal, locked, in-progress) are not rate-limited
  by this plug — they have their own caching story (immutable
  `Cache-Control` for terminal, LiveView for in-progress).
  """

  import Plug.Conn

  alias WallopCore.Resources.Draw
  alias WallopWeb.RateLimiter

  @max_attempts 120

  def init(opts), do: opts

  def call(conn, _opts) do
    case draw_status_for(extract_id(conn)) do
      :open ->
        ip = RateLimiter.ip_bucket(conn.remote_ip)

        case RateLimiter.hit("proof-pre-lock", ip, @max_attempts) do
          {:allow, _} ->
            conn

          {:deny, retry_after} ->
            conn
            |> put_status(429)
            |> Phoenix.Controller.put_view(html: WallopWeb.ErrorHTML, json: WallopWeb.ErrorJSON)
            |> put_resp_header("retry-after", Integer.to_string(retry_after))
            |> put_resp_content_type("text/plain")
            |> send_resp(429, "Too many proof-page reads. Try again in a minute.\n")
            |> halt()
        end

      _ ->
        # Not :open or not found — let the controller handle it. We
        # deliberately do NOT throttle the not-found case here, since
        # it's served by the same code path as :open and over-throttling
        # would conflate the two states and turn the rate limiter into
        # an enumeration oracle ("limited = exists as :open").
        conn
    end
  end

  @doc """
  Maximum attempts per window per IP. Public for tests.
  """
  def max_attempts, do: @max_attempts

  defp extract_id(conn) do
    case conn.params do
      %Plug.Conn.Unfetched{} -> Map.get(conn.path_params || %{}, "id")
      params when is_map(params) -> Map.get(params, "id")
      _ -> nil
    end
  end

  defp draw_status_for(nil), do: nil
  defp draw_status_for(id) when not is_binary(id), do: nil

  defp draw_status_for(id) do
    case Ash.get(Draw, id, domain: WallopCore.Domain, authorize?: false) do
      {:ok, %{status: status}} -> status
      _ -> nil
    end
  end
end
