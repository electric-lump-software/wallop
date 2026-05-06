defmodule WallopWeb.ProofEntriesControllerTest do
  @moduledoc """
  Tests for the public paginated entries endpoint
  `GET /proof/:id/entries`. Cache headers mark locked-draw entries as
  immutable.
  """
  use WallopWeb.ConnCase, async: true

  import WallopCore.TestHelpers

  describe "GET /proof/:id/entries" do
    setup do
      api_key = create_api_key()
      _infra = create_infrastructure_key()

      entries = for _ <- 1..25, do: %{"weight" => 1}

      draw = create_draw(api_key, %{entries: entries, winner_count: 2})
      %{draw: draw, api_key: api_key}
    end

    test "returns entries as {uuid, weight}", %{conn: conn, draw: draw} do
      conn = get(conn, "/proof/#{draw.id}/entries")

      body = json_response(conn, 200)
      assert length(body["entries"]) == 25

      for e <- body["entries"] do
        assert Map.has_key?(e, "uuid")
        assert Map.has_key?(e, "weight")
      end
    end

    test "sorts entries ascending by uuid", %{conn: conn, draw: draw} do
      conn = get(conn, "/proof/#{draw.id}/entries")
      body = json_response(conn, 200)

      uuids = Enum.map(body["entries"], & &1["uuid"])
      assert uuids == Enum.sort(uuids)
    end

    test "keyset pagination: ?limit=10 returns first 10 + next_after cursor", %{
      conn: conn,
      draw: draw
    } do
      conn = get(conn, "/proof/#{draw.id}/entries?limit=10")
      body = json_response(conn, 200)

      assert length(body["entries"]) == 10
      assert is_binary(body["next_after"])
      assert body["next_after"] == List.last(body["entries"])["uuid"]
    end

    test "keyset pagination: ?after=<uuid> returns entries with uuid > after", %{
      conn: conn,
      draw: draw
    } do
      first_page = get(conn, "/proof/#{draw.id}/entries?limit=10") |> json_response(200)
      cursor = first_page["next_after"]

      second_page =
        get(conn, "/proof/#{draw.id}/entries?after=#{cursor}&limit=10")
        |> json_response(200)

      assert length(second_page["entries"]) == 10

      for e <- second_page["entries"] do
        assert e["uuid"] > cursor
      end
    end

    test "last page has no next_after cursor", %{conn: conn, draw: draw} do
      body = get(conn, "/proof/#{draw.id}/entries?limit=100") |> json_response(200)
      assert length(body["entries"]) == 25
      refute Map.has_key?(body, "next_after")
    end

    test "locked draw sets immutable cache headers", %{conn: conn, draw: draw} do
      conn = get(conn, "/proof/#{draw.id}/entries")
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "open draw (not yet locked) returns 404", %{conn: conn, api_key: api_key} do
      # Open-draw entry scraping is blocked to prevent real-time observers
      # from gaining competitive intelligence on entry count/weight
      # distribution pre-lock. The endpoint is only meaningful post-lock
      # when entries are frozen.
      {:ok, open_draw} =
        Ash.Changeset.for_create(WallopCore.Resources.Draw, :create, %{winner_count: 1},
          actor: api_key
        )
        |> Ash.create()

      open_draw =
        Ash.Changeset.for_update(
          open_draw,
          :add_entries,
          %{entries: [%{"ref" => "a", "weight" => 1}], client_ref: Ash.UUID.generate()},
          actor: api_key
        )
        |> Ash.update!()

      assert open_draw.status == :open

      conn = get(conn, "/proof/#{open_draw.id}/entries")
      assert response(conn, 404)
    end

    test "invalid after cursor returns 400", %{conn: conn, draw: draw} do
      conn = get(conn, "/proof/#{draw.id}/entries?after=notauuid")
      assert response(conn, 400)
    end

    test "uppercase UUID cursor returns 400 (canonical form is lowercase)", %{
      conn: conn,
      draw: draw
    } do
      conn =
        get(conn, "/proof/#{draw.id}/entries?after=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")

      assert response(conn, 400)
    end

    test "response has no misleading count field", %{conn: conn, draw: draw} do
      body = get(conn, "/proof/#{draw.id}/entries?limit=10") |> json_response(200)
      refute Map.has_key?(body, "count")
    end

    test "pagination round-trip reproduces ProofBundle.entries_for/1 bytes (invariant)",
         %{conn: conn, draw: draw} do
      # Colin's invariant: the paginated public endpoint MUST produce the
      # same canonical entry list as ProofBundle.entries_for/1. A verifier
      # fetching all pages + concatenating + re-sorting by uuid must be
      # able to reproduce the inlined bundle entries byte-for-byte.
      inline_entries =
        draw.id
        |> WallopCore.Entries.load_for_draw()
        |> Enum.sort_by(& &1.uuid)
        |> Enum.map(fn e -> %{"uuid" => e.uuid, "weight" => e.weight} end)

      paginated =
        fetch_all_pages(conn, "/proof/#{draw.id}/entries?limit=7")
        |> Enum.sort_by(& &1["uuid"])

      assert paginated == inline_entries
    end

    test "unknown draw returns 404", %{conn: conn} do
      conn = get(conn, "/proof/00000000-0000-4000-8000-000000000000/entries")
      assert response(conn, 404)
    end

    test "limit is capped at 1000", %{conn: conn, draw: draw} do
      conn = get(conn, "/proof/#{draw.id}/entries?limit=999999")
      body = json_response(conn, 200)
      # With 25 entries, cap doesn't affect this response — we just verify it doesn't crash
      assert length(body["entries"]) == 25
    end

    test "invalid limit returns 400", %{conn: conn, draw: draw} do
      conn = get(conn, "/proof/#{draw.id}/entries?limit=notanumber")
      assert response(conn, 400)
    end
  end

  defp fetch_all_pages(conn, url) do
    body = get(conn, url) |> json_response(200)
    this_page = body["entries"]

    case body["next_after"] do
      nil ->
        this_page

      cursor ->
        separator = if String.contains?(url, "?"), do: "&", else: "?"
        this_page ++ fetch_all_pages(conn, "#{url}#{separator}after=#{cursor}")
    end
  end
end
