defmodule WallopWeb.InfrastructureControllerTest do
  use WallopWeb.ConnCase, async: false

  alias WallopCore.Protocol

  describe "GET /infrastructure/key" do
    test "returns 404 when no infrastructure key exists", %{conn: conn} do
      response =
        conn
        |> get("/infrastructure/key")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end

    test "returns the raw 32-byte public key with correct headers", %{conn: conn} do
      infra_key = create_infrastructure_key()

      resp =
        conn
        |> get("/infrastructure/key")

      assert resp.status == 200
      assert resp.resp_body == infra_key.public_key
      assert byte_size(resp.resp_body) == 32

      assert get_resp_header(resp, "content-type") |> hd() =~ "application/octet-stream"
      assert get_resp_header(resp, "cache-control") == ["public, max-age=300"]
      assert get_resp_header(resp, "x-wallop-key-id") == [infra_key.key_id]
    end

    test "returns the most recent key after rotation", %{conn: conn} do
      # Create an old key
      {old_pub, old_priv} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, old_encrypted} = WallopCore.Vault.encrypt(old_priv)

      {:ok, _old} =
        WallopCore.Resources.InfrastructureSigningKey
        |> Ash.Changeset.for_create(:create, %{
          key_id: Protocol.key_id(old_pub),
          public_key: old_pub,
          private_key: old_encrypted,
          valid_from: DateTime.add(DateTime.utc_now(), -3600, :second)
        })
        |> Ash.create(authorize?: false)

      # Create a newer key
      new_key = create_infrastructure_key()

      resp = get(conn, "/infrastructure/key")

      assert resp.status == 200
      assert resp.resp_body == new_key.public_key
      assert get_resp_header(resp, "x-wallop-key-id") == [new_key.key_id]
    end

    test "does not return a key with valid_from in the future", %{conn: conn} do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, encrypted} = WallopCore.Vault.encrypt(priv)

      {:ok, _future} =
        WallopCore.Resources.InfrastructureSigningKey
        |> Ash.Changeset.for_create(:create, %{
          key_id: Protocol.key_id(pub),
          public_key: pub,
          private_key: encrypted,
          valid_from: DateTime.add(DateTime.utc_now(), 3600, :second)
        })
        |> Ash.create(authorize?: false)

      response =
        conn
        |> get("/infrastructure/key")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end
  end
end
