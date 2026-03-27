defmodule WallopWeb.Router do
  use WallopWeb, :router

  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {WallopWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :api_authenticated do
    plug(WallopWeb.Plugs.RateLimit)
    plug(WallopWeb.Plugs.ApiKeyAuth)
    plug(:set_actor)
  end

  scope "/api", WallopWeb do
    pipe_through(:api)
    get("/open_api", ApiSpecController, :index)
    get("/docs", ApiDocsController, :index)
  end

  scope "/api/v1" do
    pipe_through([:api, :api_authenticated])

    forward("/", WallopWeb.AshJsonApiRouter)
  end

  scope "/", WallopWeb do
    pipe_through(:browser)
    live("/", HomeLive)
    live("/proof/:id", ProofLive)
  end

  if Mix.env() == :dev do
    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard",
        additional_pages: [obanalyze: Obanalyze.Dashboard]
      )

      live("/reveal-demo", WallopWeb.RevealDemoLive)
    end
  end

  scope "/", WallopWeb do
    pipe_through(:api)
    get("/health", HealthController, :index)
  end

  defp set_actor(conn, _opts) do
    case conn.assigns[:api_key] do
      nil -> conn
      api_key -> Ash.PlugHelpers.set_actor(conn, api_key)
    end
  end
end
