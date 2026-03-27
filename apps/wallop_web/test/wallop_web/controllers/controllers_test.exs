defmodule WallopWeb.ControllersTest do
  use WallopWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns status ok as JSON with 200", %{conn: conn} do
      response =
        conn
        |> get("/health")
        |> json_response(200)

      assert response == %{"status" => "ok"}
    end
  end

  describe "GET /api/open_api" do
    test "returns JSON with an info key", %{conn: conn} do
      response =
        conn
        |> get("/api/open_api")
        |> json_response(200)

      assert Map.has_key?(response, "info")
    end
  end

  describe "GET /api/docs" do
    test "returns HTML containing redoc element and spec-url", %{conn: conn} do
      response =
        conn
        |> get("/api/docs")
        |> html_response(200)

      assert response =~ "redoc"
      assert response =~ ~s(spec-url="/api/open_api")
    end
  end

  describe "WallopWeb.ErrorJSON" do
    test "renders 404 error" do
      assert WallopWeb.ErrorJSON.render("404.json", %{}) == %{
               errors: %{detail: "Not Found"}
             }
    end

    test "renders 500 error" do
      assert WallopWeb.ErrorJSON.render("500.json", %{}) == %{
               errors: %{detail: "Internal Server Error"}
             }
    end
  end
end
