defmodule WallopWeb.Plugs.ApiKeyAuthTest do
  use WallopWeb.ConnCase, async: true

  alias Ecto.Adapters.SQL
  alias WallopWeb.Plugs.ApiKeyAuth

  defp create_key_with_raw(name \\ "test key") do
    {:ok, api_key} =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

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
        |> Ash.update(authorize?: false)

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

  describe "digest verification" do
    alias WallopCore.Resources.ApiKey
    alias WallopCore.Resources.ApiKey.Digest

    defp bearer(raw), do: build_conn() |> put_req_header("authorization", "Bearer " <> raw)

    defp null_digest!(api_key) do
      SQL.query!(
        WallopCore.Repo,
        "UPDATE api_keys SET key_digest = NULL WHERE id = $1",
        [Ecto.UUID.dump!(api_key.id)]
      )
    end

    defp attach_digest_events do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:wallop_web, :api_key, :digest_recorded],
          [:wallop_web, :api_key, :digest_record_failed]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)
      ref
    end

    test "a key with a digest authenticates without bcrypt" do
      api_key = create_api_key()
      raw = api_key.__metadata__.raw_key

      SQL.query!(
        WallopCore.Repo,
        "UPDATE api_keys SET key_hash = $1 WHERE id = $2",
        [Bcrypt.hash_pwd_salt("something else"), Ecto.UUID.dump!(api_key.id)]
      )

      conn = ApiKeyAuth.call(bearer(raw), [])
      refute conn.halted
      assert conn.assigns.api_key.id == api_key.id
    end

    test "a wrong key with a matching prefix is refused and bcrypt is not consulted" do
      api_key = create_api_key()
      "wallop_" <> rest = api_key.__metadata__.raw_key
      wrong = "wallop_" <> binary_part(rest, 0, 8) <> String.duplicate("A", 35)

      SQL.query!(
        WallopCore.Repo,
        "UPDATE api_keys SET key_hash = $1 WHERE id = $2",
        [Bcrypt.hash_pwd_salt(wrong), Ecto.UUID.dump!(api_key.id)]
      )

      conn = ApiKeyAuth.call(bearer(wrong), [])
      assert conn.halted
      assert conn.status == 401
    end

    test "a key without a digest authenticates by bcrypt once and records its digest" do
      api_key = create_api_key()
      raw = api_key.__metadata__.raw_key
      null_digest!(api_key)

      ref = attach_digest_events()

      conn = ApiKeyAuth.call(bearer(raw), [])
      refute conn.halted

      assert_received {[:wallop_web, :api_key, :digest_recorded], ^ref, %{count: 1},
                       %{outcome: :recorded}}

      assert Ash.get!(ApiKey, api_key.id, authorize?: false).key_digest == Digest.compute(raw)
    end

    test "a key containing + or / authenticates" do
      api_key =
        Enum.find_value(1..50, fn _ ->
          k = create_api_key()
          if String.contains?(k.__metadata__.raw_key, ["+", "/"]), do: k
        end)

      assert api_key, "no generated key contained + or / in 50 tries"
      conn = ApiKeyAuth.call(bearer(api_key.__metadata__.raw_key), [])
      refute conn.halted
    end

    test "malformed bearers are refused" do
      for raw <- [
            "wallop_short",
            "wallop_" <> String.duplicate("A", 44),
            "nope_" <> String.duplicate("A", 43),
            "wallop_" <> String.duplicate("A", 42) <> "="
          ] do
        conn = ApiKeyAuth.call(bearer(raw), [])
        assert conn.halted, "accepted #{raw}"
        assert conn.status == 401
      end
    end

    test "an inactive key is refused" do
      api_key = create_api_key()
      raw = api_key.__metadata__.raw_key

      api_key
      |> Ash.Changeset.for_update(:deactivate, %{})
      |> Ash.update!(authorize?: false)

      assert ApiKeyAuth.call(bearer(raw), []).status == 401
    end

    test "a wrong key with a matching prefix does not poison a key without a digest" do
      api_key = create_api_key()
      "wallop_" <> rest = api_key.__metadata__.raw_key
      wrong = "wallop_" <> binary_part(rest, 0, 8) <> String.duplicate("A", 35)
      null_digest!(api_key)
      ref = attach_digest_events()

      conn = ApiKeyAuth.call(bearer(wrong), [])
      assert conn.halted
      assert conn.status == 401
      assert Ash.get!(ApiKey, api_key.id, authorize?: false).key_digest == nil
      refute_received {[:wallop_web, :api_key, :digest_recorded], ^ref, _, _}
    end

    test "the second request uses the digest, not bcrypt" do
      api_key = create_api_key()
      raw = api_key.__metadata__.raw_key
      null_digest!(api_key)

      refute ApiKeyAuth.call(bearer(raw), []).halted

      SQL.query!(WallopCore.Repo, "UPDATE api_keys SET key_hash = $1 WHERE id = $2", [
        Bcrypt.hash_pwd_salt("something else"),
        Ecto.UUID.dump!(api_key.id)
      ])

      refute ApiKeyAuth.call(bearer(raw), []).halted
    end

    test "a concurrent record of the digest is treated as success" do
      api_key = create_api_key()
      raw = api_key.__metadata__.raw_key
      null_digest!(api_key)
      stale = Ash.get!(ApiKey, api_key.id, authorize?: false)
      assert stale.key_digest == nil
      assert :ok = ApiKeyAuth.record_digest(stale, raw)

      ref = attach_digest_events()

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert :ok = ApiKeyAuth.record_digest(stale, raw)
        end)

      assert_received {[:wallop_web, :api_key, :digest_recorded], ^ref, %{count: 1},
                       %{outcome: :already_recorded}}

      refute_received {[:wallop_web, :api_key, :digest_record_failed], ^ref, _, _}
      refute log =~ "[warning]"
      assert Ash.get!(ApiKey, api_key.id, authorize?: false).key_digest == Digest.compute(raw)
    end
  end
end
