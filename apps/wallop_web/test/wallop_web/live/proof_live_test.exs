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

    test "renders verifier mode badge and disclosure text", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      conn = get(conn, "/proof/#{draw.id}")
      html = html_response(conn, 200)

      # The WASM verifier has no out-of-band key resolution yet, so
      # every browser-side check is in self-consistency mode. The
      # disclosure must say so plainly.
      assert html =~ "Mode: local self-check only"

      # The §4.2.4 caveat must be honestly disclosed: the browser-side
      # check is internally consistent but does NOT defend against a
      # tampered mirror, and the user is pointed at the CLI as the
      # tier-1 path.
      assert html =~ "tampered mirror"
      assert html =~ "What does this verify?"
      assert html =~ "wallop-verify --mode attributable"
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

      assert html =~ "in the winner list"
    end

    test "reports not found for unknown entry", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      _draw = execute_draw(draw, test_seed(), api_key)

      unknown_uuid = "00000000-0000-4000-8000-000000000000"
      conn = get(conn, "/proof/#{draw.id}?entry_id=#{unknown_uuid}")
      html = html_response(conn, 200)

      assert html =~ "Not in the winner list"
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

      assert html =~ "in the winner list"
    end

    test "auto-checks a non-winning entry via path", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_uuids = Enum.map(draw.results, & &1["entry_id"])
      all_uuids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.uuid)
      losing_uuid = Enum.find(all_uuids, fn u -> u not in winning_uuids end)

      conn = get(conn, "/proof/#{draw.id}/#{losing_uuid}")
      html = html_response(conn, 200)

      assert html =~ "Not in the winner list"
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

  describe "check_url passthrough on the static proof page" do
    test "renders the operator's check_url when a non-winner is checked", %{conn: conn} do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          check_url: "https://operator.example/check-your-ticket"
        })

      draw = execute_draw(draw, test_seed(), api_key)

      winning_uuids = Enum.map(draw.results, & &1["entry_id"])
      all_uuids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.uuid)
      losing_uuid = Enum.find(all_uuids, fn u -> u not in winning_uuids end)

      conn = get(conn, "/proof/#{draw.id}/#{losing_uuid}")
      html = html_response(conn, 200)

      assert html =~ "Not in the winner list"
      assert html =~ "https://operator.example/check-your-ticket"
      assert html =~ ~s|rel="noopener noreferrer"|
      assert html =~ ~s|target="_blank"|
    end

    test "does not render check_url when draw has none", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_uuids = Enum.map(draw.results, & &1["entry_id"])
      all_uuids = Enum.map(WallopCore.Entries.load_for_draw(draw.id), & &1.uuid)
      losing_uuid = Enum.find(all_uuids, fn u -> u not in winning_uuids end)

      conn = get(conn, "/proof/#{draw.id}/#{losing_uuid}")
      html = html_response(conn, 200)

      assert html =~ "Not in the winner list"
      refute html =~ "check-your-ticket"
      refute html =~ "ticket-check page"
    end

    test "does not render check_url on winner response", %{conn: conn} do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{
          check_url: "https://operator.example/check"
        })

      draw = execute_draw(draw, test_seed(), api_key)

      winning_id = List.first(draw.results)["entry_id"]
      conn = get(conn, "/proof/#{draw.id}/#{winning_id}")
      html = html_response(conn, 200)

      assert html =~ "in the winner list"
      # check_url is a fallback for non-winners — not shown for winners
      refute html =~ "https://operator.example/check"
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

      assert {:error, {:live_redirect, %{to: path}}} = render_click(view, "reveal_complete")
      assert path == "/proof/#{draw.id}"
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
