defmodule WallopWeb.ExampleProofTest do
  use WallopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @url "https://example.test/proof/11111111-1111-4111-8111-111111111111"
  # The schema 1 forecast draw the pages once linked to.
  @old "286838f2-c6d7-49a8-acdb-7b60bce69f35"

  setup do
    previous = Application.fetch_env(:wallop_web, :example_proof_url)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:wallop_web, :example_proof_url, value)
        :error -> Application.delete_env(:wallop_web, :example_proof_url)
      end
    end)
  end

  defp page(conn, path) do
    {:ok, _view, html} = live(conn, path)
    html
  end

  # The home page with each "how it works" tab open in turn.
  defp home_tabs(conn) do
    {:ok, view, plain} = live(conn, "/")
    crypto = render_click(view, "switch_tab", %{"tab" => "crypto"})
    {plain, crypto}
  end

  defp count(html, needle), do: length(String.split(html, needle)) - 1

  test "set: the home page links its three mentions to the example proof", %{conn: conn} do
    Application.put_env(:wallop_web, :example_proof_url, @url)
    {plain, crypto} = home_tabs(conn)

    # Two on the plain tab (organisers list, step 5); the crypto tab's one.
    assert count(plain, ~s(href="#{@url}")) == 2
    assert count(crypto, ~s(href="#{@url}")) == 2
    assert crypto =~ ~r/<a[^>]*href="#{Regex.escape(@url)}"[^>]*>full proof record<\/a>/
    refute plain =~ @old
    refute crypto =~ @old
  end

  test "set: the explainer shows the example proof button", %{conn: conn} do
    Application.put_env(:wallop_web, :example_proof_url, @url)
    html = page(conn, "/how-verification-works")

    assert html =~ ~s(href="#{@url}")
    assert html =~ "View an example proof"
  end

  test "unset: no example links, and the copy still reads", %{conn: conn} do
    Application.delete_env(:wallop_web, :example_proof_url)

    {plain, crypto} = home_tabs(conn)

    for html <- [plain, crypto], do: refute(html =~ "/proof/")
    assert plain =~ "Public proof page"
    assert plain =~ "public proof page"
    assert crypto =~ "full proof record"

    explainer = page(conn, "/how-verification-works")
    refute explainer =~ "View an example proof"
    refute explainer =~ @old
    assert explainer =~ "Every completed draw has a public proof page."
  end

  test "an empty value counts as unset" do
    Application.put_env(:wallop_web, :example_proof_url, "")
    assert WallopWeb.ExampleProof.url() == nil
  end

  describe "parse_env!/1 (EXAMPLE_PROOF_URL in runtime.exs)" do
    test "unset or empty is nil" do
      assert WallopWeb.ExampleProof.parse_env!(nil) == nil
      assert WallopWeb.ExampleProof.parse_env!("") == nil
    end

    test "an https:// URL is kept" do
      assert WallopWeb.ExampleProof.parse_env!(@url) == @url
    end

    test "anything else stops the boot" do
      for bad <- ["http://wallop.run/proof/x", "wallop.run/proof/x", "/proof/x", "https://", " "] do
        assert_raise ArgumentError, ~r/EXAMPLE_PROOF_URL must be an https:\/\/ URL/, fn ->
          WallopWeb.ExampleProof.parse_env!(bad)
        end
      end
    end
  end
end
