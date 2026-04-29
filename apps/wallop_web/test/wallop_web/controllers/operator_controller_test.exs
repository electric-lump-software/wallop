defmodule WallopWeb.OperatorControllerTest do
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers

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
end
