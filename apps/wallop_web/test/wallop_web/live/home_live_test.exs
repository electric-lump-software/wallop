defmodule WallopWeb.HomeLiveTest do
  use WallopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "home page" do
    test "loads successfully and shows headline", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Run a draw nobody"
    end

    test "shows open source badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Open source"
    end

    test "shows nav links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Results"
      assert html =~ "Pricing"
      assert html =~ "Join waitlist"
    end

    # Ticker commented out — re-enable when wired to real data
    # test "shows live draws ticker", %{conn: conn} do
    #   {:ok, _view, html} = live(conn, "/")
    #   assert html =~ "Live draws"
    #   assert html =~ "PTA"
    # end

    test "shows why provable section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Why it matters"
      assert html =~ "The proof is permanent"
    end

    test "shows for organisers section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "For organisers"
      assert html =~ "Public proof page"
      assert html =~ "for every draw"
    end

    test "shows for developers section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "For developers"
      assert html =~ "fair_pick"
    end

    test "plain english tab is active by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "locked box"
      refute html =~ "Durstenfeld"
    end

    test "switching to cryptographic tab shows technical content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = view |> element("button", "Cryptographic detail") |> render_click()
      assert html =~ "Durstenfeld"
      assert html =~ "SHA256"
      refute html =~ "locked box"
    end

    test "switching back to plain english tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> element("button", "Cryptographic detail") |> render_click()
      html = view |> element("button", "Plain English") |> render_click()
      assert html =~ "locked box"
      refute html =~ "Durstenfeld"
    end

    test "shows trust section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Verify it yourself"
      assert html =~ "electric-lump-software"
    end

    test "shows origin story section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Why Wallop"
      assert html =~ "Hampshire"
    end

    test "shows faq section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Is the result actually random"
      assert html =~ "drand beacon"
    end

    test "shows waitlist form with email input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Be first to know"
      assert html =~ ~r/type="email"/
    end

    test "shows footer with origin reference", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Made in Britain"
    end
  end

  describe "waitlist signup" do
    test "successful signup shows confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> form("#waitlist form", %{email: "new@example.com"})
        |> render_submit()

      assert html =~ "on the list"
    end

    test "duplicate email shows same confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Submit once
      view
      |> form("#waitlist form", %{email: "dup@example.com"})
      |> render_submit()

      # Submit again with a fresh view (form is gone after first submit)
      {:ok, view2, _html} = live(conn, "/")

      html =
        view2
        |> form("#waitlist form", %{email: "dup@example.com"})
        |> render_submit()

      assert html =~ "on the list"
    end

    test "empty email shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> form("#waitlist form", %{email: ""})
        |> render_submit()

      assert html =~ "valid email"
    end
  end
end
