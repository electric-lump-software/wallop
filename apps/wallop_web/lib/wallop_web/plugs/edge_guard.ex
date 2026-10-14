defmodule WallopWeb.Plugs.EdgeGuard do
  @moduledoc """
  Refuses requests that didn't come through the edge (CDN).

  `RemoteIp` trusts the edge's client-IP header, which is only safe if
  nobody can reach the origin directly. When the origin's platform can't
  restrict who connects, configure the edge to add a secret request header
  and set the same value here (`EDGE_SHARED_SECRET`). Requests without it
  get 403.

  `GET /health` is exempt so the platform's internal healthcheck, which
  doesn't pass through the edge, keeps working. `HEAD /health` is not
  exempt (the platform's healthcheck uses GET). With no secret configured
  (self-hosting, dev, test) the plug does nothing.

  The header is removed after the check so nothing downstream can log it.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @header "x-edge-secret"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["health"]} = conn, _opts),
    do: delete_req_header(conn, @header)

  def call(conn, _opts) do
    case secret() do
      nil -> conn
      secret -> check(conn, secret)
    end
  end

  defp check(conn, ""), do: refuse(conn)

  defp check(conn, secret) do
    case get_req_header(conn, @header) do
      [given] ->
        if Plug.Crypto.secure_compare(given, secret),
          do: delete_req_header(conn, @header),
          else: refuse(conn)

      _ ->
        refuse(conn)
    end
  end

  defp refuse(conn) do
    Logger.warning("edge guard refused request: #{conn.method} #{conn.request_path}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "Forbidden\n")
    |> halt()
  end

  defp secret do
    :wallop_web |> Application.get_env(__MODULE__, []) |> Keyword.get(:secret)
  end
end
