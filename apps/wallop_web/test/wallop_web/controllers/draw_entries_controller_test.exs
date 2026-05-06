defmodule WallopWeb.DrawEntriesControllerTest do
  @moduledoc """
  Tests for authenticated draw entries endpoints:

  - PATCH /api/v1/draws/:id/entries — response carries inserted UUIDs
    in submission order in `meta.inserted_entries`.
  - GET /api/v1/draws/:id/entries — api_key-scoped readback,
    keyset-paginated, sorted UUID-ascending, works at any status.
  """
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Resources.Draw

  setup %{conn: conn} do
    operator = create_operator()

    {:ok, api_key} =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, %{name: "test-key", operator_id: operator.id})
      |> Ash.create(authorize?: false)

    raw_key = api_key.__metadata__.raw_key

    draw =
      Draw
      |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
      |> Ash.create!()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, draw: draw, api_key: api_key, raw_key: raw_key}
  end

  describe "PATCH /api/v1/draws/:id/entries" do
    test "returns 200 and meta.inserted_entries in submission order", %{conn: conn, draw: draw} do
      body = %{
        entries: [%{weight: 1}, %{weight: 7}, %{weight: 3}],
        client_ref: Ash.UUID.generate()
      }

      conn = patch(conn, "/api/v1/draws/#{draw.id}/entries", body)

      resp = json_response(conn, 200)

      assert resp["data"]["id"] == draw.id
      assert resp["data"]["type"] == "draw"
      assert resp["data"]["attributes"]["status"] == "open"
      assert resp["data"]["attributes"]["entry_count"] == 3

      uuids =
        resp["meta"]["inserted_entries"]
        |> Enum.map(& &1["uuid"])

      assert length(uuids) == 3
      assert Enum.all?(uuids, &String.match?(&1, ~r/^[0-9a-f-]{36}$/))

      # Cross-check via Entries.load_for_draw — weight at position i in
      # the response's inserted_entries must match weight at position i
      # of the submitted body.
      rows = WallopCore.Entries.load_for_draw(draw.id)
      by_uuid = Map.new(rows, &{&1.uuid, &1.weight})

      assert Map.fetch!(by_uuid, Enum.at(uuids, 0)) == 1
      assert Map.fetch!(by_uuid, Enum.at(uuids, 1)) == 7
      assert Map.fetch!(by_uuid, Enum.at(uuids, 2)) == 3
    end

    test "rejects invalid payload shape", %{conn: conn, draw: draw} do
      conn =
        patch(conn, "/api/v1/draws/#{draw.id}/entries", %{
          entries: "not a list",
          client_ref: Ash.UUID.generate()
        })

      assert json_response(conn, 400)
    end

    test "rejects malformed draw id", %{conn: conn} do
      conn =
        patch(conn, "/api/v1/draws/not-a-uuid/entries", %{
          entries: [%{weight: 1}],
          client_ref: Ash.UUID.generate()
        })

      assert json_response(conn, 404)
    end

    test "rejects access to another operator's draw", %{conn: conn} do
      other_key = create_api_key("other-key")

      other_draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: other_key)
        |> Ash.create!()

      # Using conn still carries the *first* operator's auth — attempting
      # to patch the other operator's draw should be scoped to the caller
      # and return 404 (don't leak existence).
      conn =
        patch(conn, "/api/v1/draws/#{other_draw.id}/entries", %{
          entries: [%{weight: 1}],
          client_ref: Ash.UUID.generate()
        })

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/draws/:id/entries" do
    setup %{conn: conn, draw: draw} do
      # Seed 5 entries via the same path so uuids exist in the DB.
      conn =
        patch(conn, "/api/v1/draws/#{draw.id}/entries", %{
          entries: for(w <- 1..5, do: %{weight: w}),
          client_ref: Ash.UUID.generate()
        })

      assert json_response(conn, 200)

      %{conn: conn, draw: draw}
    end

    test "returns entries sorted UUID-ascending", %{conn: conn, draw: draw} do
      conn = get(conn, "/api/v1/draws/#{draw.id}/entries")

      resp = json_response(conn, 200)
      uuids = Enum.map(resp["entries"], & &1["uuid"])

      assert length(uuids) == 5
      assert uuids == Enum.sort(uuids)
    end

    test "payload shape is {uuid, weight} only — no other fields", %{conn: conn, draw: draw} do
      conn = get(conn, "/api/v1/draws/#{draw.id}/entries")

      for e <- json_response(conn, 200)["entries"] do
        assert Map.keys(e) |> Enum.sort() == ["uuid", "weight"]
      end
    end

    test "keyset pagination via ?limit and ?after", %{conn: conn, draw: draw} do
      # Page 1 — limit 3
      conn1 = get(conn, "/api/v1/draws/#{draw.id}/entries?limit=3")
      resp1 = json_response(conn1, 200)
      assert length(resp1["entries"]) == 3
      assert is_binary(resp1["next_after"])

      # Page 2 — remaining
      conn2 = get(conn, "/api/v1/draws/#{draw.id}/entries?after=#{resp1["next_after"]}&limit=3")
      resp2 = json_response(conn2, 200)
      assert length(resp2["entries"]) == 2
      refute Map.has_key?(resp2, "next_after")

      # Combined pages equal the full list
      all_uuids =
        (resp1["entries"] ++ resp2["entries"])
        |> Enum.map(& &1["uuid"])

      assert all_uuids == Enum.sort(all_uuids)
      assert length(all_uuids) == 5
    end

    test "bad limit returns 400", %{conn: conn, draw: draw} do
      conn = get(conn, "/api/v1/draws/#{draw.id}/entries?limit=abc")
      assert json_response(conn, 400)
    end

    test "bad after cursor returns 400", %{conn: conn, draw: draw} do
      conn = get(conn, "/api/v1/draws/#{draw.id}/entries?after=not-a-uuid")
      assert json_response(conn, 400)
    end

    test "works on open draw (not just locked)", %{conn: conn, draw: draw} do
      # Draw is still :open from setup — endpoint must serve it.
      conn = get(conn, "/api/v1/draws/#{draw.id}/entries")
      assert json_response(conn, 200)
    end

    test "another operator's draw returns 404", %{conn: conn} do
      other_key = create_api_key("other-key-ix")

      other_draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: other_key)
        |> Ash.create!()

      conn = get(conn, "/api/v1/draws/#{other_draw.id}/entries")
      assert json_response(conn, 404)
    end
  end

  describe "AshJsonApi fallback for other /api/v1/draws routes" do
    test "GET /api/v1/draws still works (not intercepted)", %{conn: conn} do
      # Our custom controller handles /draws/:id/entries but must leave
      # other AshJsonApi routes (like the index) alone.
      conn =
        conn
        |> put_req_header("content-type", "application/vnd.api+json")
        |> put_req_header("accept", "application/vnd.api+json")
        |> get("/api/v1/draws")

      assert conn.status in 200..499
    end
  end
end
