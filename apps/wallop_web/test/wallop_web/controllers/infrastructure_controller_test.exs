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
      # Create an "older" key. The keyring temporal binding CHECK caps
      # valid_from drift at ±60s from inserted_at, so the offset stays
      # inside the window — what's being tested is the rotation pick logic
      # (largest valid_from <= now), not arbitrary historical inserts.
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

      # Create a newer key
      new_key = create_infrastructure_key()

      resp = get(conn, "/infrastructure/key")

      assert resp.status == 200
      assert resp.resp_body == new_key.public_key
      assert get_resp_header(resp, "x-wallop-key-id") == [new_key.key_id]
    end

    test "does not return a key with valid_from in the future", %{conn: conn} do
      # Future-dated rows beyond the ±60s skew window are rejected by the
      # CHECK constraint at insert time. This test exercises the
      # controller's `valid_from <= now` filter for a key whose valid_from
      # sits inside the skew window but still ahead of now.
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

      # Spec §4.2.1 canonical RFC 3339: `YYYY-MM-DDTHH:MM:SS.<6 digits>Z`,
      # exactly 27 bytes. The verifier's `chrono_parse_canonical` regex
      # requires this precise form — anything else (no fractional seconds,
      # different precision, `+00:00` instead of `Z`) rejects.
      canonical = ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

      assert key["inserted_at"] =~ canonical,
             "inserted_at #{inspect(key["inserted_at"])} must match canonical RFC 3339 form"

      # `valid_from` is deliberately NOT on the wire — see the infra
      # controller comment for the V-02 backdating-window rationale.
      refute Map.has_key?(key, "valid_from")
    end

    test "includes rotated keys so historical receipts stay verifiable",
         %{conn: conn} do
      # Older rotation slot — within ±60s skew window so the keyring
      # CHECK constraint accepts the row.
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

      # Sorted ascending by inserted_at (which mirrors valid_from within
      # the ±60s keyring CHECK skew window).
      [first, second] = response["keys"]
      assert first["inserted_at"] < second["inserted_at"]

      # Every entry carries the canonical fields including key_class.
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
      # Spec §4.2.4 pins the keys-list envelope as exactly
      # `{schema_version, keys}` under `schema_version: "1"`.
      # Conforming verifiers reject any extra top-level field. This
      # regression test pins the discipline so a future friendly
      # extension cannot quietly break tier-2 / tier-1 verification
      # in the field. Mirrors the operator-endpoint test.
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
