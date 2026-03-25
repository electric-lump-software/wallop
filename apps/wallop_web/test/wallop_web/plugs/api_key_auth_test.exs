defmodule WallopWeb.Plugs.ApiKeyAuthTest do
  use WallopWeb.ConnCase, async: true

  alias WallopWeb.Plugs.ApiKeyAuth

  defp create_key_with_raw(name \\ "test key") do
    {:ok, api_key} =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create()

    raw_key = api_key.__metadata__.raw_key
    {api_key, raw_key}
  end

  defp auth_conn(conn, raw_key) do
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  describe "valid API key" do
    test "assigns api_key to conn and does not halt", %{conn: conn} do
      {api_key, raw_key} = create_key_with_raw()

      result = conn |> auth_conn(raw_key) |> ApiKeyAuth.call([])

      assert result.assigns.api_key.id == api_key.id
      refute result.halted
    end
  end

  describe "missing authorization header" do
    test "returns 401 and halts", %{conn: conn} do
      result = ApiKeyAuth.call(conn, [])

      assert result.status == 401
      assert result.halted
    end
  end

  describe "invalid key (wrong body)" do
    test "returns 401 and halts when key body does not match hash", %{conn: conn} do
      {_api_key, _raw_key} = create_key_with_raw()

      wrong_key = "wallop_AAAAAAAA" <> String.duplicate("X", 40)
      result = conn |> auth_conn(wrong_key) |> ApiKeyAuth.call([])

      assert result.status == 401
      assert result.halted
    end
  end

  describe "deactivated key" do
    test "returns 401 and halts", %{conn: conn} do
      {api_key, raw_key} = create_key_with_raw()

      {:ok, _} =
        api_key
        |> Ash.Changeset.for_update(:deactivate, %{})
        |> Ash.update()

      result = conn |> auth_conn(raw_key) |> ApiKeyAuth.call([])

      assert result.status == 401
      assert result.halted
    end
  end

  describe "malformed key (not starting with wallop_)" do
    test "returns 401 and halts", %{conn: conn} do
      result = conn |> auth_conn("invalid_key_format") |> ApiKeyAuth.call([])

      assert result.status == 401
      assert result.halted
    end
  end
end
