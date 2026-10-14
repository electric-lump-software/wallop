defmodule WallopWeb.Api.ErrorShapeTest do
  use WallopWeb.ConnCase, async: true

  import WallopCore.TestHelpers

  defp api(conn, key) do
    conn
    |> put_req_header("authorization", "Bearer #{key.__metadata__.raw_key}")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> put_req_header("accept", "application/vnd.api+json")
  end

  defp body(id, attrs), do: %{"data" => %{"type" => "draw", "id" => id, "attributes" => attrs}}

  setup %{conn: conn} do
    key = create_api_key()

    draw =
      WallopCore.Resources.Draw
      |> Ash.Changeset.for_create(:create, %{winner_count: 3}, actor: key)
      |> Ash.create!()

    %{conn: conn, key: key, draw: draw}
  end

  test "lock errors point at the attribute", %{conn: conn, key: key, draw: draw} do
    [error] =
      conn
      |> api(key)
      |> patch("/api/v1/draws/#{draw.id}/lock", body(draw.id, %{}))
      |> json_response(400)
      |> Map.fetch!("errors")

    assert error["source"]["pointer"] == "/data/attributes/entries"
    assert error["detail"] == "draw has no entries"
  end

  test "update constraint errors point at the attribute and interpolate the message",
       %{conn: conn, key: key, draw: draw} do
    [error] =
      conn
      |> api(key)
      |> patch("/api/v1/draws/#{draw.id}/winner_count", body(draw.id, %{"winner_count" => 0}))
      |> json_response(400)
      |> Map.fetch!("errors")

    assert error["source"]["pointer"] == "/data/attributes/winner_count"
    assert error["detail"] == "must be greater than or equal to 1"
  end

  test "create errors are unchanged apart from the message", %{conn: conn, key: key} do
    [error] =
      conn
      |> api(key)
      |> post("/api/v1/draws", %{"data" => %{"type" => "draw", "attributes" => %{"winner_count" => 0}}})
      |> json_response(400)
      |> Map.fetch!("errors")

    assert error["source"]["pointer"] == "/data/attributes/winner_count"
    assert error["detail"] == "must be greater than or equal to 1"
  end
end
