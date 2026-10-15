defmodule WallopWeb.Plugs.CanonicalUrlTest do
  use WallopWeb.ConnCase, async: false

  alias WallopWeb.Plugs.CanonicalUrl

  test "an https endpoint URL wins over the plain-HTTP connection", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-forwarded-proto", "http")
      |> put_req_header("x-forwarded-host", "evil.example")
      |> CanonicalUrl.call(url: [host: "wallop.example", port: 443, scheme: "https"])

    assert conn.scheme == :https
    assert conn.host == "wallop.example"
    assert conn.port == 443
    assert Plug.Conn.request_url(conn) =~ ~r{^https://wallop\.example/}
  end

  test "a non-https endpoint URL leaves the conn alone", %{conn: conn} do
    out = CanonicalUrl.call(conn, url: [host: "wallop.example", port: 4000])
    assert {out.scheme, out.host, out.port} == {conn.scheme, conn.host, conn.port}
  end

  describe "with an https endpoint URL configured" do
    setup do
      original = Application.get_env(:wallop_web, WallopWeb.Endpoint)

      Application.put_env(
        :wallop_web,
        WallopWeb.Endpoint,
        Keyword.put(original, :url, host: "wallop.example", port: 443, scheme: "https")
      )

      on_exit(fn -> Application.put_env(:wallop_web, WallopWeb.Endpoint, original) end)
    end

    test "links.next starts with the configured public base URL", %{conn: conn} do
      key = WallopCore.TestHelpers.create_api_key()

      for _ <- 1..2 do
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: key)
        |> Ash.create!()
      end

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{key.__metadata__.raw_key}")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/draws?page[limit]=1")
        |> json_response(200)

      assert String.starts_with?(resp["links"]["next"], "https://wallop.example/api/v1/draws?")
    end
  end
end
