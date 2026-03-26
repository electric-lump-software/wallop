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

      html = view |> element("button", "Re-verify results") |> render_click()

      assert html =~ "Results verified"
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
        WallopWeb.PubSub,
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
  end
end
