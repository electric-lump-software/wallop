defmodule WallopWeb.ProofLiveTest do
  use WallopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WallopCore.TestHelpers

  describe "mount" do
    test "renders completed draw with verification badge", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      {:ok, _view, html} = live(conn, "/proof/#{draw.id}")

      assert html =~ "Verified by Wallop"
    end

    test "renders in-progress draw with timeline", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      {:ok, _view, html} = live(conn, "/proof/#{draw.id}")

      assert html =~ "Entries Locked"
      assert html =~ "Entropy Declared"
    end

    test "redirects for nonexistent draw", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, "/proof/00000000-0000-0000-0000-000000000000")
    end
  end

  describe "re-verify" do
    test "verifies a completed draw", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      {:ok, view, _html} = live(conn, "/proof/#{draw.id}")

      # Verify button is rendered (animation handled by JS hook)
      assert render(view) =~ "Re-verify results"

      # Simulate the hook firing the re_verify event
      # Result is pushed to JS via push_event, not rendered server-side
      view |> element("#verify-animation") |> render_hook("re_verify", %{})
    end
  end

  describe "entry check" do
    test "finds a winning entry", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      winning_id = List.first(draw.results)["entry_id"]

      {:ok, view, _html} = live(conn, "/proof/#{draw.id}")

      html =
        view
        |> form("form", %{entry_id: winning_id})
        |> render_submit()

      assert html =~ "Position" or html =~ "position" or html =~ "won"
    end

    test "reports not found for unknown entry", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      {:ok, view, _html} = live(conn, "/proof/#{draw.id}")

      html =
        view
        |> form("form", %{entry_id: "nonexistent-entry-id"})
        |> render_submit()

      assert html =~ "not found"
    end
  end

  describe "PubSub updates" do
    test "re-renders when draw is updated via PubSub", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      {:ok, view, html} = live(conn, "/proof/#{draw.id}")

      # Should show timeline (not completed)
      refute html =~ "Verified by Wallop"

      # Execute the draw to get a completed struct
      completed_draw = execute_draw(draw, test_seed(), api_key)

      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "draw:#{draw.id}",
        {:draw_updated, completed_draw}
      )

      # Give the LiveView time to process the message — it enters reveal state first
      html = render(view)
      assert html =~ "Verifying..."

      # Simulate the JS hook firing reveal_complete
      render_click(view, "reveal_complete")
      html = render(view)

      assert html =~ "Verified by Wallop"
    end

    test "ignores PubSub update for different draw", %{conn: conn} do
      api_key = create_api_key()
      draw_a = create_draw(api_key, %{})
      draw_b = create_draw(api_key, %{})

      {:ok, view, html} = live(conn, "/proof/#{draw_a.id}")
      refute html =~ "Verified by Wallop"

      completed_draw_b = execute_draw(draw_b, test_seed(), api_key)

      # Broadcast update for draw_b while viewing draw_a — should be ignored
      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "draw:#{draw_a.id}",
        {:draw_updated, completed_draw_b}
      )

      html = render(view)
      # The page should still show draw_a (not completed)
      refute html =~ "Verified by Wallop"
    end

    test "updates draw when status hasn't changed (non-reveal update)", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      {:ok, view, _html} = live(conn, "/proof/#{draw.id}")

      # Broadcast the same locked draw (same status — triggers true branch in maybe_reveal)
      Phoenix.PubSub.broadcast(
        WallopCore.PubSub,
        "draw:#{draw.id}",
        {:draw_updated, draw}
      )

      # Should not crash and should still render the timeline
      html = render(view)
      assert html =~ "Entries Locked"
    end
  end

  describe "failed draw" do
    test "renders timeline for failed draw", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      {:ok, failed_draw} =
        draw
        |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "entropy timeout"},
          authorize?: false
        )
        |> Ash.update(domain: WallopCore.Domain, authorize?: false)

      {:ok, _view, html} = live(conn, "/proof/#{failed_draw.id}")

      assert html =~ "entropy timeout"
      assert html =~ "failed" or html =~ "step-error"
    end
  end

  describe "open draw" do
    test "renders timeline for open draw with entries", %{conn: conn} do
      api_key = create_api_key()

      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "entry-1", "weight" => 1}, %{"id" => "entry-2", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      {:ok, _view, html} = live(conn, "/proof/#{draw.id}")

      assert html =~ "Entries Open"
    end
  end

  describe "completed draw proof chain" do
    test "shows proof chain with entry hash, seed, and algorithm link", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})
      draw = execute_draw(draw, test_seed(), api_key)

      {:ok, _view, html} = live(conn, "/proof/#{draw.id}")

      assert html =~ draw.entry_hash
      assert html =~ draw.seed
      assert html =~ "fair_pick"
    end
  end
end
