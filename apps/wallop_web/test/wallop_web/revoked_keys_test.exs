defmodule WallopWeb.RevokedKeysTest do
  use WallopWeb.ConnCase, async: false

  require Ash.Query

  alias WallopCore.Protocol
  alias WallopCore.Protocol.Pin
  alias WallopCore.Resources.{InfrastructureSigningKey, OperatorSigningKey}

  defp add_infra_key!(offset_seconds) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, encrypted} = WallopCore.Vault.encrypt(private_key)

    InfrastructureSigningKey
    |> Ash.Changeset.for_create(:create, %{
      key_id: Protocol.key_id(public_key),
      public_key: public_key,
      private_key: encrypted,
      valid_from: DateTime.add(DateTime.utc_now(), offset_seconds, :second)
    })
    |> Ash.create!(authorize?: false)
  end

  defp add_operator_key!(operator, offset_seconds) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, encrypted} = WallopCore.Vault.encrypt(private_key)

    OperatorSigningKey
    |> Ash.Changeset.for_create(:create, %{
      operator_id: operator.id,
      key_id: Protocol.key_id(public_key),
      public_key: public_key,
      private_key: encrypted,
      valid_from: DateTime.add(DateTime.utc_now(), offset_seconds, :second)
    })
    |> Ash.create!(authorize?: false)
  end

  defp served_key_ids(response), do: Enum.map(response["keys"], & &1["key_id"])

  describe "the infrastructure endpoints" do
    setup do
      kept = add_infra_key!(-50)
      revoked = add_infra_key!(-10) |> revoke_key!()
      %{kept: kept, revoked: revoked}
    end

    test "GET /infrastructure/keys omits a revoked key", %{conn: conn, kept: kept} do
      response = conn |> get("/infrastructure/keys") |> json_response(200)

      assert served_key_ids(response) == [kept.key_id]
      assert response["schema_version"] == "1"

      assert Map.keys(hd(response["keys"])) |> Enum.sort() ==
               ~w(inserted_at key_class key_id public_key_hex)
    end

    test "GET /infrastructure/key never serves a revoked key", %{conn: conn, kept: kept} do
      resp = get(conn, "/infrastructure/key")

      assert resp.status == 200
      assert get_resp_header(resp, "x-wallop-key-id") == [kept.key_id]
    end
  end

  describe "the operator endpoints" do
    setup do
      operator = create_operator()
      [kept] = OperatorSigningKey |> Ash.Query.filter(operator_id == ^operator.id) |> Ash.read!()
      revoked = operator |> add_operator_key!(-5) |> revoke_key!()
      %{operator: operator, kept: kept, revoked: revoked}
    end

    test "GET /operator/:slug/keys omits a revoked key", %{conn: conn} = ctx do
      response = conn |> get("/operator/#{ctx.operator.slug}/keys") |> json_response(200)

      assert served_key_ids(response) == [ctx.kept.key_id]
      assert response["schema_version"] == "1"
    end

    test "GET /operator/:slug/key never serves a revoked key", %{conn: conn} = ctx do
      resp = get(conn, "/operator/#{ctx.operator.slug}/key")

      assert resp.status == 200
      assert get_resp_header(resp, "x-wallop-key-id") == [ctx.kept.key_id]
    end

    test "keyring-pin.json lists no revoked operator key and is signed by an unrevoked infra key",
         %{conn: conn} = ctx do
      kept_infra = add_infra_key!(-50)
      add_infra_key!(-10) |> revoke_key!()

      response =
        conn
        |> get("/operator/#{ctx.operator.slug}/keyring-pin.json")
        |> json_response(200)

      assert served_key_ids(response) == [ctx.kept.key_id]

      preimage = response |> Map.delete("infrastructure_signature") |> Jcs.encode()
      signature = Base.decode16!(response["infrastructure_signature"], case: :lower)
      assert Pin.verify(preimage, signature, kept_infra.public_key)
    end
  end
end
