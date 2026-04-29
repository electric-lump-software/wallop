defmodule WallopWeb.OperatorControllerTest do
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers

  require Ash.Query
  alias WallopCore.Protocol.Pin

  describe "GET /operator/:slug/keys" do
    test "returns 404 for an unknown slug", %{conn: conn} do
      response =
        conn
        |> get("/operator/does-not-exist/keys")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end

    test "returns each operator key with key_id, public_key_hex, inserted_at, key_class",
         %{conn: conn} do
      operator = create_operator("acme")

      response =
        conn
        |> get("/operator/#{operator.slug}/keys")
        |> json_response(200)

      # spec §4.2.4 — top-level `schema_version` pins the wire shape so
      # resolver-driven verifiers can reject unknown shapes terminally.
      assert response["schema_version"] == "1"
      assert %{"keys" => [key]} = response
      assert is_binary(key["key_id"])
      assert String.match?(key["key_id"], ~r/^[0-9a-f]{8}$/)
      assert is_binary(key["public_key_hex"])
      assert String.match?(key["public_key_hex"], ~r/^[0-9a-f]{64}$/)
      assert is_binary(key["inserted_at"])

      # `valid_from` is deliberately NOT on the wire. Producer-side state
      # held within ±60s of `inserted_at` by the keyring CHECK; emitting
      # it would invite resolver implementations to compare it against
      # the receipt's binding timestamp instead of `inserted_at`,
      # reopening the V-02 backdating window. The canonical pin shape is
      # the four fields above.
      refute Map.has_key?(key, "valid_from")

      # key_class discriminates operator vs infrastructure keys per the
      # spec §4.2.4 temporal binding rule. This endpoint serves only
      # :operator-class keys.
      assert key["key_class"] == "operator"
    end

    test "inserted_at matches the spec §4.2.1 canonical RFC 3339 form",
         %{conn: conn} do
      operator = create_operator("canonical-form")

      response =
        conn
        |> get("/operator/#{operator.slug}/keys")
        |> json_response(200)

      [key] = response["keys"]

      # Spec §4.2.1 canonical RFC 3339: `YYYY-MM-DDTHH:MM:SS.<6 digits>Z`,
      # exactly 27 bytes. The verifier's `chrono_parse_canonical` regex
      # requires this precise form — anything else (no fractional seconds,
      # different precision, `+00:00` instead of `Z`) rejects.
      #
      # If a future schema migration changes the keyring column from
      # `:utc_datetime_usec` to `:utc_datetime`, Jason emits the second-
      # precision form (no fractional) and the verifier silently rejects
      # every key. This test fails first.
      canonical = ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

      assert key["inserted_at"] =~ canonical,
             "inserted_at #{inspect(key["inserted_at"])} must match canonical RFC 3339 form"
    end

    test "inserted_at corresponds to the keyring row append time", %{conn: conn} do
      operator = create_operator("inserted-at-time")

      response =
        conn
        |> get("/operator/#{operator.slug}/keys")
        |> json_response(200)

      [key] = response["keys"]
      {:ok, parsed, _} = DateTime.from_iso8601(key["inserted_at"])

      # Should be within a few seconds of "now" since the operator was just
      # created in the test setup.
      delta_seconds = DateTime.diff(DateTime.utc_now(), parsed, :second)
      assert delta_seconds >= 0
      assert delta_seconds < 60
    end

    test "response envelope is closed-set under schema_version 1 (only `schema_version` and `keys`)",
         %{conn: conn} do
      # Spec §4.2.4 pins the keys-list envelope as exactly
      # `{schema_version, keys}` under `schema_version: "1"`.
      # Conforming verifiers (`wallop_verifier ≥ 0.14.0`) reject any
      # extra top-level field via `deny_unknown_fields` — so emitting a
      # friendly extension here breaks tier-2 attestable verification
      # for everyone. This regression test pins the closed-set
      # discipline server-side; without it the next "harmless" friendly
      # field lands the same way.
      operator = create_operator("closed-set")

      response =
        conn
        |> get("/operator/#{operator.slug}/keys")
        |> json_response(200)

      actual_top_level_keys = response |> Map.keys() |> Enum.sort()

      assert actual_top_level_keys == ["keys", "schema_version"],
             "spec §4.2.4 envelope is closed-set under schema_version=1; " <>
               "got #{inspect(actual_top_level_keys)}, expected [\"keys\", \"schema_version\"]"

      [key] = response["keys"]
      actual_row_keys = key |> Map.keys() |> Enum.sort()

      assert actual_row_keys == ["inserted_at", "key_class", "key_id", "public_key_hex"],
             "spec §4.2.4 row is closed-set; got #{inspect(actual_row_keys)}, " <>
               "expected [\"inserted_at\", \"key_class\", \"key_id\", \"public_key_hex\"]"
    end
  end

  describe "GET /operator/:slug/keyring-pin.json" do
    test "returns 404 for an unknown slug", %{conn: conn} do
      ensure_infrastructure_key()

      response =
        conn
        |> get("/operator/does-not-exist/keyring-pin.json")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end

    test "returns 404 (not 503) when the operator has no signing keys yet (greenfield)",
         %{conn: conn} do
      # Create an operator directly, WITHOUT minting a signing key.
      # `create_operator/1` always seeds a key, so we go around it.
      {:ok, operator} =
        WallopCore.Resources.Operator
        |> Ash.Changeset.for_create(:create, %{slug: "no-keys-yet", name: "Greenfield Op"})
        |> Ash.create(authorize?: false)

      ensure_infrastructure_key()

      response =
        conn
        |> get("/operator/#{operator.slug}/keyring-pin.json")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end

    test "returns 404 (not 503) when no infrastructure key has been bootstrapped yet",
         %{conn: conn} do
      operator = create_operator("pin-no-infra-key")

      # Forcibly delete any infrastructure keys that exist in the
      # test sandbox so we can exercise the greenfield-no-infra path.
      WallopCore.Resources.InfrastructureSigningKey
      |> Ash.read!(authorize?: false)
      |> Enum.each(&Ash.destroy!(&1, authorize?: false))

      response =
        conn
        |> get("/operator/#{operator.slug}/keyring-pin.json")
        |> json_response(404)

      assert response == %{"error" => "not found"}
    end

    test "returns a valid signed pin envelope", %{conn: conn} do
      operator = create_operator("pin-roundtrip")
      infra_key = ensure_get_infrastructure_key()

      response =
        conn
        |> get("/operator/#{operator.slug}/keyring-pin.json")
        |> json_response(200)

      assert response["schema_version"] == "1"
      assert response["operator_slug"] == to_string(operator.slug)
      assert is_list(response["keys"])
      assert response["keys"] != []
      assert is_binary(response["published_at"])
      assert is_binary(response["infrastructure_signature"])

      # Reconstruct the pre-image per spec §4.2.4 verifier obligation:
      # parse, drop infrastructure_signature, JCS-canonicalise.
      preimage =
        response
        |> Map.delete("infrastructure_signature")
        |> Jcs.encode()

      sig = Base.decode16!(response["infrastructure_signature"], case: :lower)

      assert Pin.verify(preimage, sig, infra_key.public_key),
             "Ed25519 signature MUST verify against the infrastructure public key " <>
               "with the wallop-pin-v1 domain separator prepended"
    end

    test "envelope is closed-set under schema_version 1", %{conn: conn} do
      # Spec §4.2.4 pin shape is exactly five top-level fields. Any extra
      # field on the wire breaks third-party verifier conformance and is
      # subject to the same closed-set discipline as the keys-list endpoint.
      operator = create_operator("pin-closed-set")
      ensure_infrastructure_key()

      response =
        conn
        |> get("/operator/#{operator.slug}/keyring-pin.json")
        |> json_response(200)

      actual_top_level_keys = response |> Map.keys() |> Enum.sort()

      assert actual_top_level_keys ==
               [
                 "infrastructure_signature",
                 "keys",
                 "operator_slug",
                 "published_at",
                 "schema_version"
               ],
             "spec §4.2.4 pin envelope is closed-set under schema_version=1; " <>
               "got #{inspect(actual_top_level_keys)}"

      [first_row | _] = response["keys"]
      actual_row_keys = first_row |> Map.keys() |> Enum.sort()

      assert actual_row_keys == ["key_class", "key_id", "public_key_hex"],
             "spec §4.2.4 pin row is closed-set; got #{inspect(actual_row_keys)}, " <>
               "expected [\"key_class\", \"key_id\", \"public_key_hex\"]"
    end

    test "every keys[] row is operator-class only", %{conn: conn} do
      operator = create_operator("pin-class")
      ensure_infrastructure_key()

      response =
        conn
        |> get("/operator/#{operator.slug}/keyring-pin.json")
        |> json_response(200)

      Enum.each(response["keys"], fn row ->
        assert row["key_class"] == "operator"
      end)
    end

    test "keys[] is sorted ascending by key_id (byte-order, lowercase hex)", %{conn: conn} do
      operator = create_operator("pin-sort")
      ensure_infrastructure_key()

      # Mint two extra operator keys so sort order is non-trivially observable.
      add_extra_operator_key(operator)
      add_extra_operator_key(operator)

      response =
        conn
        |> get("/operator/#{operator.slug}/keyring-pin.json")
        |> json_response(200)

      key_ids = Enum.map(response["keys"], & &1["key_id"])
      assert key_ids == Enum.sort(key_ids), "keys[] must be sorted ascending by key_id"
    end

    test "published_at matches the spec §4.2.1 canonical RFC 3339 form", %{conn: conn} do
      operator = create_operator("pin-timestamp")
      ensure_infrastructure_key()

      response =
        conn
        |> get("/operator/#{operator.slug}/keyring-pin.json")
        |> json_response(200)

      canonical = ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/
      assert response["published_at"] =~ canonical
    end

    test "Cache-Control header is public, max-age=60", %{conn: conn} do
      operator = create_operator("pin-cache")
      ensure_infrastructure_key()

      conn = get(conn, "/operator/#{operator.slug}/keyring-pin.json")
      assert get_resp_header(conn, "cache-control") == ["public, max-age=60"]
    end
  end

  defp ensure_get_infrastructure_key do
    ensure_infrastructure_key()

    [key] =
      WallopCore.Resources.InfrastructureSigningKey
      |> Ash.Query.sort(valid_from: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    key
  end

  defp add_extra_operator_key(operator) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = WallopCore.Protocol.key_id(public_key)
    {:ok, encrypted} = WallopCore.Vault.encrypt(private_key)

    {:ok, _} =
      WallopCore.Resources.OperatorSigningKey
      |> Ash.Changeset.for_create(:create, %{
        operator_id: operator.id,
        key_id: key_id,
        public_key: public_key,
        private_key: encrypted,
        valid_from: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      |> Ash.create(authorize?: false)
  end
end
