defmodule WallopWeb.HomeLiveTest do
  use WallopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "home page" do
    test "loads successfully and shows headline", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Random isn&#39;t enough"
      assert html =~ "fair, and provably fair. Wallop! does both."
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

      view
      |> form("#waitlist form", %{email: "dup@example.com"})
      |> render_submit()

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

  describe "public claims about the randomness" do
    @overclaims [
      "two independent sources",
      "two completely independent",
      "every draw comes",
      "nobody (including us)",
      "Neither is predictable",
      "impossible",
      "guarantee",
      "Open-Meteo",
      "Wittering",
      "can question",
      "rests on"
    ]

    test "the home page, both tabs, makes none of the old overclaims", %{conn: conn} do
      {:ok, view, plain} = live(conn, "/")
      crypto = render_click(view, "switch_tab", %{"tab" => "crypto"})

      for html <- [plain, crypto], phrase <- @overclaims do
        refute html =~ phrase, "home page still says #{inspect(phrase)}"
      end

      assert plain =~ "The proof shows exactly what went in."

      for html <- [plain, crypto] do
        refute html =~ ~r/forecast/i
        refute html =~ ~r/collud|ganging/i
      end
    end

    test "how verification works names the fallbacks and what is trusted", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/how-verification-works")

      for phrase <- @overclaims do
        refute html =~ phrase, "how-verification-works still says #{inspect(phrase)}"
      end

      assert html =~ "The National Grid"
      assert html =~ "drand does it alone"
      assert html =~ "Proven, and trusted."
      assert html =~ "can cancel a draw only before then, and visibly"
      assert html =~ "within tolerance after that"
      refute html =~ "not even we can UPDATE"
      refute html =~ ~r/forecast/i

      [body, small_print] = String.split(html, ~s(id="small-print"), parts: 2)
      refute body =~ ~r/collud|ganging/i
      assert small_print =~ "fewer than drand&#39;s threshold of nodes collude"
      assert html =~ "the drand beacon is"
    end
  end
end
