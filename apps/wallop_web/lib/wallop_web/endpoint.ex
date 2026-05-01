defmodule WallopWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :wallop_web

  @session_options [
    store: :cookie,
    key: "_wallop_key",
    signing_salt: "wLp3Xk9R",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]],
    longpoll: [connect_info: [:peer_data, :x_headers, session: @session_options]]
  )

  plug(Plug.Static,
    at: "/",
    from: :wallop_web,
    gzip: not code_reloading?,
    only: WallopWeb.static_paths()
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)

  # Rewrite `conn.remote_ip` from the trusted proxy header written by
  # the CDN/edge layer. The edge strips any client-supplied value of
  # this header before forwarding, so the value can be treated as
  # authoritative.
  #
  # IMPORTANT: this is only safe while the edge → origin path is
  # protected so an attacker cannot bypass the edge and supply their
  # own header value. Origin protection is a deploy-platform concern,
  # not an app concern, but the security of this plug depends on it.
  plug(RemoteIp, headers: ~w(cf-connecting-ip))

  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    # 1 MB ceiling on user-supplied request bodies. The largest legitimate
    # body is `add_entries` at the per-draw entry cap (10 000 entries × ~80
    # bytes ≈ 800 KB). Default Plug.Parsers limit is 8 MB, which lets a
    # single legitimate api key wedge a worker on parse cost alone before
    # any business validator fires.
    length: 1_048_576
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  plug(WallopWeb.Plugs.PdfExtensionRewrite)
  plug(WallopWeb.Plugs.JsonExtensionRewrite)

  plug(WallopWeb.Router)
end
