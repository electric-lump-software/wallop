defmodule WallopWeb.ApiSpecController do
  use WallopWeb, :controller

  def index(conn, _params) do
    json(conn, WallopWeb.ApiSpec.generate())
  end
end
