defmodule WallopWeb.Api.DrawsListTest do
  use WallopWeb.ConnCase, async: true

  import WallopCore.TestHelpers

  defp authed(conn, key) do
    conn
    |> put_req_header("authorization", "Bearer #{key.__metadata__.raw_key}")
    |> put_req_header("accept", "application/vnd.api+json")
  end

  defp open_draw(key) do
    WallopCore.Resources.Draw
    |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: key)
    |> Ash.create!()
  end

  defp ids(resp), do: Enum.map(resp["data"], & &1["id"])

  test "lists only the caller's draws, oldest first", %{conn: conn} do
    key = create_api_key()
    a = open_draw(key)
    b = open_draw(key)
    _other = open_draw(create_api_key())

    resp = conn |> authed(key) |> get("/api/v1/draws") |> json_response(200)
    assert ids(resp) == [a.id, b.id]
  end

  test "filters by one or more statuses", %{conn: conn} do
    key = create_api_key()
    open = open_draw(key)
    locked = create_draw(key)

    assert ids(conn |> authed(key) |> get("/api/v1/draws?status=open") |> json_response(200)) ==
             [open.id]

    assert ids(
             conn
             |> authed(key)
             |> get("/api/v1/draws?status=awaiting_entropy")
             |> json_response(200)
           ) == [locked.id]

    assert ids(
             conn
             |> authed(key)
             |> get("/api/v1/draws?status=open,awaiting_entropy")
             |> json_response(200)
           ) == [open.id, locked.id]
  end

  test "rejects bad status values with a 400 naming the allowed values", %{conn: conn} do
    key = create_api_key()

    for bad <- ["", "nope", "open,", "OPEN", "open,nope"] do
      resp = conn |> authed(key) |> get("/api/v1/draws?status=#{URI.encode_www_form(bad)}")
      assert resp.status == 400, "status=#{inspect(bad)} gave #{resp.status}"
      assert resp.resp_body =~ "awaiting_entropy"
    end
  end

  # Keyset paging is not a snapshot: a draw created concurrently can commit
  # with an inserted_at behind a cursor already handed out. With one writer,
  # as here, nothing is skipped or repeated.
  test "pages with page[limit] and page[after]; a draw created after a page was read appears later (single writer)",
       %{conn: conn} do
    key = create_api_key()
    [d1, d2, d3] = for _ <- 1..3, do: open_draw(key)

    page1 = conn |> authed(key) |> get("/api/v1/draws?page[limit]=2") |> json_response(200)
    assert ids(page1) == [d1.id, d2.id]
    assert next = page1["links"]["next"]

    d4 = open_draw(key)

    page2 = conn |> authed(key) |> get(next) |> json_response(200)
    assert ids(page2) == [d3.id, d4.id]
  end

  test "a page size above 100 is reduced to 100", %{conn: conn} do
    key = create_api_key()
    for _ <- 1..101, do: open_draw(key)

    resp = conn |> authed(key) |> get("/api/v1/draws?page[limit]=500") |> json_response(200)
    assert length(resp["data"]) == 100
    assert resp["links"]["next"]
  end
end
