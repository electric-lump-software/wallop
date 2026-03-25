defmodule WallopWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :api_authenticated do
    plug(WallopWeb.Plugs.RateLimit)
    plug(WallopWeb.Plugs.ApiKeyAuth)
    plug(:set_actor)
  end

  scope "/api/v1" do
    pipe_through([:api, :api_authenticated])

    forward("/", WallopWeb.AshJsonApiRouter)
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
