defmodule WallopWeb.Api.DrawsTest do
  use WallopWeb.ConnCase, async: true

  defp create_key_with_raw(name \\ "test key") do
    {:ok, api_key} =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create()

    raw_key = api_key.__metadata__.raw_key
    {api_key, raw_key}
  end

  defp auth_conn(conn, raw_key) do
    conn
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> put_req_header("accept", "application/vnd.api+json")
  end

  defp unauth_conn(conn) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> put_req_header("accept", "application/vnd.api+json")
  end

  defp draw_payload(attrs \\ %{}) do
    defaults = %{
      "entries" => [
        %{"id" => "ticket-47", "weight" => 1},
        %{"id" => "ticket-48", "weight" => 1},
        %{"id" => "ticket-49", "weight" => 1}
      ],
      "winner_count" => 2
    }

    %{
      "data" => %{
        "type" => "draw",
        "attributes" => Map.merge(defaults, attrs)
      }
    }
  end

  describe "POST /api/v1/draws" do
    test "creates a draw with valid auth", %{conn: conn} do
      {_api_key, raw_key} = create_key_with_raw()

      resp =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/draws", draw_payload())
        |> json_response(201)

      assert %{"data" => data} = resp
      assert data["type"] == "draw"
      assert data["attributes"]["status"] == "locked"
      assert is_binary(data["attributes"]["entry_hash"])
      assert data["attributes"]["winner_count"] == 2
      assert data["id"]
    end

    test "returns 401 without auth", %{conn: conn} do
      conn
      |> unauth_conn()
      |> post("/api/v1/draws", draw_payload())
      |> json_response(401)
    end
  end

  describe "GET /api/v1/draws/:id" do
    test "returns a draw with valid auth", %{conn: conn} do
      {api_key, raw_key} = create_key_with_raw()
      draw = create_draw(api_key)

      resp =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/draws/#{draw.id}")
        |> json_response(200)

      assert %{"data" => data} = resp
      assert data["id"] == draw.id
      assert data["type"] == "draw"
      assert data["attributes"]["status"] == "locked"
    end
  end

  describe "GET /api/v1/draws" do
    test "returns list of draws for authenticated key", %{conn: conn} do
      {api_key, raw_key} = create_key_with_raw()
      create_draw(api_key)
      create_draw(api_key)

      resp =
        conn
        |> auth_conn(raw_key)
        |> get("/api/v1/draws")
        |> json_response(200)

      assert %{"data" => data} = resp
      assert length(data) == 2
    end

    test "returns 401 without auth", %{conn: conn} do
      conn
      |> unauth_conn()
      |> get("/api/v1/draws")
      |> json_response(401)
    end
  end

  describe "PATCH /api/v1/draws/:id/execute" do
    test "executes a draw with a valid seed", %{conn: conn} do
      {api_key, raw_key} = create_key_with_raw()
      draw = create_draw(api_key)

      payload = %{
        "data" => %{
          "type" => "draw",
          "id" => draw.id,
          "attributes" => %{
            "seed" => test_seed()
          }
        }
      }

      resp =
        conn
        |> auth_conn(raw_key)
        |> patch("/api/v1/draws/#{draw.id}/execute", payload)
        |> json_response(200)

      assert %{"data" => data} = resp
      assert data["attributes"]["status"] == "completed"
      assert is_list(data["attributes"]["results"])
      assert length(data["attributes"]["results"]) == 2
    end
  end
end
