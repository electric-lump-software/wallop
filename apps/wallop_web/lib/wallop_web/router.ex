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
    plug(WallopWeb.Plugs.KeyRateLimit)
    plug(WallopWeb.Plugs.TierLimit)
    plug(:set_actor)
  end

  scope "/api", WallopWeb do
    pipe_through(:api)
    get("/open_api", ApiSpecController, :index)
    get("/docs", ApiDocsController, :index)
  end

  scope "/api/v1" do
    pipe_through([:api, :api_authenticated])

    get("/health", WallopWeb.ApiHealthController, :index)

    # Custom handlers for draw entries — take precedence over the generic
    # AshJsonApi route. `:create` returns `meta.inserted_entries` alongside
    # the draw; `:index` is the authenticated readback endpoint for
    # post-ingest UUID recovery and manifest construction.
    patch("/draws/:id/entries", WallopWeb.DrawEntriesController, :create)
    get("/draws/:id/entries", WallopWeb.DrawEntriesController, :index)

    # Wildcard forward to AshJsonApi. Anything an Ash resource exposes via
    # `json_api do` is auto-mounted here. The route surface is pinned by
    # `WallopWeb.RouterRoutesTest` (see
    # `apps/wallop_web/test/wallop_web/router_routes_test.exs`); a new
    # resource × action under the wildcard fails that test until the
    # allowlist is updated intentionally.
    forward("/", WallopWeb.AshJsonApiRouter)
  end

  scope "/", WallopWeb do
    pipe_through(:browser)
    live("/", HomeLive)
    get("/proof/:id/pdf", ProofPdfController, :show)
    get("/proof/:id/json", ProofBundleController, :show)
    get("/proof/:id/entries", ProofController, :entries_index)
    get("/proof/:id/:entry_id", ProofController, :show)
    get("/proof/:id", ProofController, :show)
    live("/live/proof/:id/:entry_id", ProofLive)
    live("/live/proof/:id", ProofLive)
    live("/operator/:slug", OperatorLive)
    live("/transparency", TransparencyLive)
    live("/how-verification-works", HowVerificationWorksLive)
  end

  scope "/infrastructure", WallopWeb do
    pipe_through(:api)
    get("/key", InfrastructureController, :key_pub)
    get("/keys", InfrastructureController, :keys_index)
  end

  scope "/operator", WallopWeb do
    pipe_through(:api)
    get("/:slug/receipts", OperatorController, :receipts_index)
    get("/:slug/receipts/:sequence", OperatorController, :receipt_show)
    get("/:slug/executions", OperatorController, :executions_index)
    get("/:slug/executions/:sequence", OperatorController, :execution_show)
    get("/:slug/keys", OperatorController, :keys_index)
    get("/:slug/key", OperatorController, :key_pub)
    get("/:slug/keyring-pin.json", OperatorController, :keyring_pin)
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
