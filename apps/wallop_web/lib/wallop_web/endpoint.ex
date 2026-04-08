defmodule WallopWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :wallop_web

  @session_options [
    store: :cookie,
    key: "_wallop_key",
    signing_salt: "wLp3Xk9R",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
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
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  plug(WallopWeb.Plugs.PdfExtensionRewrite)

  plug(WallopWeb.Router)
end
