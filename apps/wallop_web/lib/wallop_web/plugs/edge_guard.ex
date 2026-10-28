defmodule WallopWeb.Plugs.EdgeGuard do
  @moduledoc """
  Refuses requests that didn't come through the edge (CDN).

  `RemoteIp` trusts the edge's client-IP header, which is only safe if
  nobody can reach the origin directly. When the origin's platform can't
  restrict who connects, configure the edge to add a secret request header
  and set the same value here (`EDGE_SHARED_SECRET`). Requests without it
  get 403.

  To rotate the value without refusing anything, set the new value as
  `EDGE_SHARED_SECRET` and the old one as `EDGE_SHARED_SECRET_PREVIOUS`,
  deploy, switch the edge to the new value, then remove the previous one
  and deploy again. While both are set, either is accepted, and every
  request that arrives with the previous value logs a warning, so the
  logs show when the edge has switched and the previous value can go. A
  previous value nobody meant to set is visible the same way, and at boot.

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
    case secrets() do
      [] -> conn
      secrets -> check(conn, secrets)
    end
  end

  defp check(conn, secrets) do
    with [given] <- get_req_header(conn, @header),
         {:ok, which} <- match(given, secrets) do
      if which == :previous do
        Logger.warning(
          "edge guard accepted the previous edge secret: #{conn.method} #{conn.request_path}"
        )
      end

      delete_req_header(conn, @header)
    else
      _ -> refuse(conn)
    end
  end

  defp match(given, secrets) do
    matches =
      for {which, secret} <- secrets,
          do: {which, secret != "" and Plug.Crypto.secure_compare(given, secret)}

    case Enum.find(matches, fn {_which, matched} -> matched end) do
      {which, true} -> {:ok, which}
      nil -> :error
    end
  end

  defp refuse(conn) do
    Logger.warning("edge guard refused request: #{conn.method} #{conn.request_path}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "Forbidden\n")
    |> halt()
  end

  defp secrets do
    config = Application.get_env(:wallop_web, __MODULE__, [])

    case {Keyword.get(config, :secret), Keyword.get(config, :previous_secret)} do
      {nil, _previous} -> []
      {secret, nil} -> [current: secret]
      {secret, previous} -> [current: secret, previous: previous]
    end
  end
end
