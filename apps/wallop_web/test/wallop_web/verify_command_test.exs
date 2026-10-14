defmodule WallopWeb.VerifyCommandTest do
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers

  alias WallopWeb.VerifyCommand

  setup do
    previous = Application.get_env(:wallop_web, :verify_block_anchor_mode)

    on_exit(fn ->
      Application.put_env(:wallop_web, :verify_block_anchor_mode, previous)
    end)

    :ok
  end

  defp completed_draw do
    operator = create_operator()
    api_key = create_api_key_for_operator(operator)
    draw = create_draw(api_key, %{})
    {operator, execute_draw(draw, test_seed(), api_key)}
  end

  defp escaped(string), do: string |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  describe "bundled anchor mode (default)" do
    setup do
      Application.put_env(:wallop_web, :verify_block_anchor_mode, :bundled)
      :ok
    end

    test "fills in every identifier and no trust anchor", %{conn: conn} do
      {operator, draw} = completed_draw()
      base_url = WallopWeb.Endpoint.url()

      html = conn |> get("/proof/#{draw.id}") |> html_response(200)

      assert html =~ "--wallop-base-url #{base_url}"
      assert html =~ "--pin-from-url #{base_url}/operator/#{operator.slug}/keyring-pin.json"
      assert html =~ "#{draw.id}.json</pre>"

      refute html =~ "--infra-key-pin"
      refute html =~ "proof-bundle.json"
      refute html =~ "&lt;slug&gt;"
      refute html =~ "this instance"
    end

    test "takes the base URL from endpoint config, not the Host header", %{conn: conn} do
      {_operator, draw} = completed_draw()

      html =
        %{conn | host: "evil.example"}
        |> get("/proof/#{draw.id}")
        |> html_response(200)

      refute html =~ "evil.example"
    end
  end

  describe "self anchor mode" do
    setup do
      Application.put_env(:wallop_web, :verify_block_anchor_mode, :self)
      :ok
    end

    test "pins every infrastructure key exactly as /infrastructure/keys publishes it", %{
      conn: conn
    } do
      {_operator, draw} = completed_draw()
      # A second key, so a draw executed before a rotation still verifies.
      create_infrastructure_key()

      published = conn |> get("/infrastructure/keys") |> json_response(200)
      assert length(published["keys"]) >= 2

      html = build_conn() |> get("/proof/#{draw.id}") |> html_response(200)

      for key <- published["keys"] do
        record =
          ~s({"key_id":"#{key["key_id"]}","public_key_hex":"#{key["public_key_hex"]}",) <>
            ~s("inserted_at":"#{key["inserted_at"]}","revoked_at":null})

        assert html =~ escaped("--infra-key-pin '#{record}'")
      end

      assert length(String.split(html, escaped("--infra-key-pin '"))) - 1 ==
               length(published["keys"])

      assert html =~ "this instance publishes, not that it"
    end
  end

  test "returns nil without an operator" do
    assert VerifyCommand.build(Ecto.UUID.generate(), nil) == nil
  end
end
