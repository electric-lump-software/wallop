defmodule WallopWeb.ProofLiveTest do
  use WallopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WallopCore.TestHelpers

  describe "completed draw (static controller)" do
    test "renders completed draw with verification badge", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      assert html =~ "Verified by Wallop"
    end

    test "renders download proof bundle button", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      assert html =~ "Download proof bundle (JSON)"
      assert html =~ "/proof/#{draw.id}.json"
    end

    test "renders verify block with receipt data attributes", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      assert html =~ "data-lock-receipt-jcs"
      assert html =~ "data-lock-signature-hex"
      assert html =~ "data-operator-public-key-hex"
      assert html =~ "data-execution-receipt-jcs"
      assert html =~ "data-execution-signature-hex"
      assert html =~ "data-infra-public-key-hex"
    end

    test "sets immutable cache headers", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]
    end

    test "shows proof chain with entry hash, seed, and algorithm link", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      assert html =~ draw.entry_hash
      assert html =~ draw.seed
      assert html =~ "fair_pick"
    end
  end

  describe "entry check (static controller)" do
    test "finds a winning entry via query param", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_id = List.first(draw.results)["entry_id"]

      conn = get(conn, "/proof/#{draw.id}?entry_id=#{winning_id}")
      html = html_response(conn, 200)

      assert html =~ "won"
    end

    test "reports not found for unknown entry", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      _draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}?entry_id=nonexistent-id")
      html = html_response(conn, 200)

      assert html =~ "not found"
    end
  end

  describe "direct entry check link" do
    test "auto-checks a winning entry via path", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_id = List.first(draw.results)["entry_id"]

      conn = get(conn, "/proof/#{draw.id}/#{winning_id}")
      html = html_response(conn, 200)

      assert html =~ "won"
    end

    test "auto-checks a non-winning entry via path", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_ids = Enum.map(draw.results, & &1["entry_id"])
      all_ids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.id)
      losing_id = Enum.find(all_ids, fn id -> id not in winning_ids end)

      conn = get(conn, "/proof/#{draw.id}/#{losing_id}")
      html = html_response(conn, 200)

      assert html =~ "did not win"
    end

    test "pre-fills the entry ID input", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_id = List.first(draw.results)["entry_id"]

      conn = get(conn, "/proof/#{draw.id}/#{winning_id}")
      html = html_response(conn, 200)

      assert html =~ "value=\"#{winning_id}\""
    end
  end

  describe "in-progress draw (LiveView redirect)" do
    test "redirects to LiveView for in-progress draw", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      conn = get(conn, "/proof/#{draw.id}")

      assert redirected_to(conn) =~ "/live/proof/#{draw.id}"
    end

    test "renders timeline in LiveView", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      {:ok, _view, html} = live(conn, "/live/proof/#{draw.id}")

      assert html =~ "Entries Locked"
      assert html =~ "Entropy Declared"
    end
  end

  describe "failed draw (static controller)" do
    test "renders failed draw with failure reason", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      {:ok, failed_draw} =
        draw
        |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "entropy timeout"},
          authorize?: false
        )
        |> Ash.update(domain: WallopCore.Domain, authorize?: false)

      conn = get(conn, "/proof/#{failed_draw.id}")
      html = html_response(conn, 200)

      assert html =~ "entropy timeout"
    end
  end

  describe "open draw (LiveView redirect)" do
    test "redirects open draw to LiveView", %{conn: conn} do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      conn = get(conn, "/proof/#{draw.id}")

      assert redirected_to(conn) =~ "/live/proof/#{draw.id}"
    end
  end

  describe "nonexistent draw" do
    test "redirects for nonexistent draw", %{conn: conn} do
      conn = get(conn, "/proof/00000000-0000-0000-0000-000000000000")

      assert redirected_to(conn) == "/"
    end
  end

  describe "PubSub updates (LiveView)" do
    test "re-renders when draw is updated via PubSub", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      {:ok, view, html} = live(conn, "/live/proof/#{draw.id}")

      refute html =~ "Verified by Wallop"

      completed_draw = execute_draw(draw, test_seed(), api_key)

      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "draw:#{draw.id}",
        {:draw_updated, completed_draw}
      )

      html = render(view)
      assert html =~ "Verifying..."

      render_click(view, "reveal_complete")
      html = render(view)

      assert html =~ "Verified by Wallop"
    end

    test "ignores PubSub update for different draw", %{conn: conn} do
      api_key = create_api_key()
      draw_a = create_draw(api_key, %{})
      draw_b = create_draw(api_key, %{})

      {:ok, view, html} = live(conn, "/live/proof/#{draw_a.id}")
      refute html =~ "Verified by Wallop"

      completed_draw_b = execute_draw(draw_b, test_seed(), api_key)

      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "draw:#{draw_a.id}",
        {:draw_updated, completed_draw_b}
      )

      html = render(view)
      refute html =~ "Verified by Wallop"
    end

    test "updates draw when status hasn't changed", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      {:ok, view, _html} = live(conn, "/live/proof/#{draw.id}")

      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "draw:#{draw.id}",
        {:draw_updated, draw}
      )

      html = render(view)
      assert html =~ "Entries Locked"
    end
  end
end
