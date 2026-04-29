defmodule WallopWeb.ApiHealthController do
  @moduledoc """
  Authenticated API health check endpoint.

  Returns 200 with {"status": "ok"} if the API key is valid and
  the service is healthy. Used by integrators as a liveness probe.
  """
  use WallopWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
