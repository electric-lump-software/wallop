defmodule WallopWeb.Api.DrawsTest do
  use WallopWeb.ConnCase, async: true

  defp create_key_with_raw(name \\ "test key") do
    {:ok, api_key} =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

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
    test "creates an open draw with valid auth", %{conn: conn} do
      {_api_key, raw_key} = create_key_with_raw()

      resp =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/draws", draw_payload())
        |> json_response(201)

      assert %{"data" => data} = resp
      assert data["type"] == "draw"
      assert data["attributes"]["status"] == "open"
      assert data["attributes"]["winner_count"] == 2
      assert data["id"]
      # Open draws have no entry_hash or entropy until locked
      assert data["attributes"]["entry_hash"] == nil
      assert data["attributes"]["drand_chain"] == nil
      assert data["attributes"]["drand_round"] == nil
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
      assert data["attributes"]["status"] == "awaiting_entropy"
    end
  end

  describe "PATCH /api/v1/draws/:id/entries" do
    test "adds entries to an open draw", %{conn: conn} do
      {_api_key, raw_key} = create_key_with_raw()

      # Create open draw
      create_resp =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/draws", draw_payload())
        |> json_response(201)

      draw_id = create_resp["data"]["id"]

      # Add entries
      entries_payload = %{
        "data" => %{
          "type" => "draw",
          "id" => draw_id,
          "attributes" => %{
            "entries" => [
              %{"id" => "a", "weight" => 1},
              %{"id" => "b", "weight" => 1}
            ]
          }
        }
      }

      resp =
        conn
        |> auth_conn(raw_key)
        |> patch("/api/v1/draws/#{draw_id}/entries", entries_payload)
        |> json_response(200)

      assert resp["data"]["attributes"]["status"] == "open"
      assert resp["data"]["attributes"]["entry_count"] == 2
    end
  end

  describe "PATCH /api/v1/draws/:id/lock" do
    test "locks an open draw with entries", %{conn: conn} do
      {_api_key, raw_key} = create_key_with_raw()

      # Create open draw
      create_resp =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/draws", draw_payload())
        |> json_response(201)

      draw_id = create_resp["data"]["id"]

      # Add entries
      entries_payload = %{
        "data" => %{
          "type" => "draw",
          "id" => draw_id,
          "attributes" => %{
            "entries" => [
              %{"id" => "a", "weight" => 1},
              %{"id" => "b", "weight" => 1},
              %{"id" => "c", "weight" => 1}
            ]
          }
        }
      }

      conn
      |> auth_conn(raw_key)
      |> patch("/api/v1/draws/#{draw_id}/entries", entries_payload)
      |> json_response(200)

      # Lock the draw
      lock_payload = %{
        "data" => %{
          "type" => "draw",
          "id" => draw_id,
          "attributes" => %{}
        }
      }

      resp =
        conn
        |> auth_conn(raw_key)
        |> patch("/api/v1/draws/#{draw_id}/lock", lock_payload)
        |> json_response(200)

      assert resp["data"]["attributes"]["status"] == "awaiting_entropy"
      assert is_binary(resp["data"]["attributes"]["entry_hash"])
      assert is_binary(resp["data"]["attributes"]["drand_chain"])
      assert is_integer(resp["data"]["attributes"]["drand_round"])
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

  describe "API open draw flow" do
    test "draws created via API start in open status", %{conn: conn} do
      {_api_key, raw_key} = create_key_with_raw()

      payload = %{
        "data" => %{
          "type" => "draw",
          "attributes" => %{
            "winner_count" => 1
          }
        }
      }

      resp =
        conn
        |> auth_conn(raw_key)
        |> post("/api/v1/draws", payload)
        |> json_response(201)

      assert resp["data"]["attributes"]["status"] == "open"
      assert resp["data"]["attributes"]["drand_round"] == nil
    end

    test "caller-seed execute endpoint is not exposed via API", %{conn: conn} do
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

      conn
      |> auth_conn(raw_key)
      |> patch("/api/v1/draws/#{draw.id}/execute", payload)
      |> json_response(404)
    end
  end
end
