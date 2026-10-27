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
      {old_pub, old_priv} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, old_encrypted} = WallopCore.Vault.encrypt(old_priv)

      {:ok, _old} =
        WallopCore.Resources.InfrastructureSigningKey
        |> Ash.Changeset.for_create(:create, %{
          key_id: Protocol.key_id(old_pub),
          public_key: old_pub,
          private_key: old_encrypted,
          valid_from: DateTime.add(DateTime.utc_now(), -45, :second)
        })
        |> Ash.create(authorize?: false)

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
          valid_from: DateTime.add(DateTime.utc_now(), 45, :second)
        })
        |> Ash.create(authorize?: false)

      response =
        conn
        |> get("/infrastructure/key")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end
  end

  describe "GET /infrastructure/keys" do
    test "returns the canonical keys-list shape (spec §4.2.4) for an empty keyring",
         %{conn: conn} do
      response =
        conn
        |> get("/infrastructure/keys")
        |> json_response(200)

      assert response["schema_version"] == "1"
      assert response["keys"] == []
    end

    test "returns the active key with all required fields", %{conn: conn} do
      infra_key = create_infrastructure_key()

      response =
        conn
        |> get("/infrastructure/keys")
        |> json_response(200)

      assert response["schema_version"] == "1"
      assert length(response["keys"]) == 1

      [key] = response["keys"]
      assert key["key_id"] == infra_key.key_id
      assert key["public_key_hex"] == Base.encode16(infra_key.public_key, case: :lower)
      assert key["key_class"] == "infrastructure"

      canonical = ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

      assert key["inserted_at"] =~ canonical,
             "inserted_at #{inspect(key["inserted_at"])} must match canonical RFC 3339 form"

      refute Map.has_key?(key, "valid_from")
    end

    test "includes rotated keys so historical receipts stay verifiable",
         %{conn: conn} do
      {old_pub, old_priv} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, old_encrypted} = WallopCore.Vault.encrypt(old_priv)

      {:ok, _old} =
        WallopCore.Resources.InfrastructureSigningKey
        |> Ash.Changeset.for_create(:create, %{
          key_id: Protocol.key_id(old_pub),
          public_key: old_pub,
          private_key: old_encrypted,
          valid_from: DateTime.add(DateTime.utc_now(), -45, :second)
        })
        |> Ash.create(authorize?: false)

      _new = create_infrastructure_key()

      response =
        conn
        |> get("/infrastructure/keys")
        |> json_response(200)

      assert length(response["keys"]) == 2

      [first, second] = response["keys"]
      assert first["inserted_at"] < second["inserted_at"]

      canonical = ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

      Enum.each(response["keys"], fn k ->
        assert is_binary(k["key_id"])
        assert is_binary(k["public_key_hex"])
        assert k["key_class"] == "infrastructure"
        assert k["inserted_at"] =~ canonical
        refute Map.has_key?(k, "valid_from")
      end)
    end

    test "sets cache-control public, max-age=300", %{conn: conn} do
      _ = create_infrastructure_key()

      resp = get(conn, "/infrastructure/keys")

      assert resp.status == 200
      assert get_resp_header(resp, "cache-control") == ["public, max-age=300"]
    end

    test "response envelope is closed-set under schema_version 1 (only `schema_version` and `keys`)",
         %{conn: conn} do
      _ = create_infrastructure_key()

      response =
        conn
        |> get("/infrastructure/keys")
        |> json_response(200)

      actual_top_level_keys = response |> Map.keys() |> Enum.sort()

      assert actual_top_level_keys == ["keys", "schema_version"],
             "spec §4.2.4 envelope is closed-set under schema_version=1; " <>
               "got #{inspect(actual_top_level_keys)}"

      [key] = response["keys"]
      actual_row_keys = key |> Map.keys() |> Enum.sort()

      assert actual_row_keys == ["inserted_at", "key_class", "key_id", "public_key_hex"],
             "spec §4.2.4 row is closed-set; got #{inspect(actual_row_keys)}"
    end
  end
end
