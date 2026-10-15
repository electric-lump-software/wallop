defmodule WallopCore.Resources.ApiKeyTest do
  use WallopCore.DataCase, async: true

  alias Ash.Resource.Info
  alias WallopCore.Resources.ApiKey

  defp create_key(name \\ "test key") do
    ApiKey
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create(authorize?: false)
  end

  describe "create" do
    test "stores a bcrypt hash and 8-char prefix" do
      {:ok, key} = create_key()

      assert byte_size(key.key_hash) > 0
      assert String.length(key.key_prefix) == 8
    end

    test "raw key is available in metadata and starts with wallop_" do
      {:ok, key} = create_key()

      raw_key = key.__metadata__.raw_key
      assert String.starts_with?(raw_key, "wallop_")
    end

    test "prefix is the first 8 chars of the random portion" do
      {:ok, key} = create_key()

      raw_key = key.__metadata__.raw_key
      random_part = String.replace_prefix(raw_key, "wallop_", "")
      assert key.key_prefix == String.slice(random_part, 0, 8)
    end

    test "bcrypt hash verifies against the raw key" do
      {:ok, key} = create_key()

      raw_key = key.__metadata__.raw_key
      assert Bcrypt.verify_pass(raw_key, key.key_hash)
    end

    test "key has active=true by default" do
      {:ok, key} = create_key()

      assert key.active == true
    end
  end

  describe "deactivate" do
    test "sets active=false and records deactivated_at" do
      {:ok, key} = create_key()

      {:ok, deactivated} =
        key
        |> Ash.Changeset.for_update(:deactivate, %{})
        |> Ash.update(authorize?: false)

      assert deactivated.active == false
      assert deactivated.deactivated_at != nil
    end
  end

  describe "tier metadata" do
    test "tier defaults to nil and limit defaults to nil (unlimited)" do
      {:ok, key} = create_key()
      assert key.tier == nil
      assert key.monthly_draw_limit == nil
      assert key.monthly_draw_count == 0
      assert key.count_reset_at == nil
    end

    test "create accepts tier metadata" do
      {:ok, reset_at} = DateTime.new(~D[2026-05-01], ~T[00:00:00.000000], "Etc/UTC")

      {:ok, key} =
        ApiKey
        |> Ash.Changeset.for_create(:create, %{
          name: "test",
          tier: "starter",
          monthly_draw_limit: 50,
          count_reset_at: reset_at
        })
        |> Ash.create(authorize?: false)

      assert key.tier == "starter"
      assert key.monthly_draw_limit == 50
      assert key.count_reset_at == reset_at
    end
  end

  describe "update_tier" do
    test "updates tier metadata on an existing key" do
      {:ok, key} = create_key()
      {:ok, reset_at} = DateTime.new(~D[2026-05-01], ~T[00:00:00.000000], "Etc/UTC")

      {:ok, updated} =
        key
        |> Ash.Changeset.for_update(:update_tier, %{
          tier: "pro",
          monthly_draw_limit: 1000,
          count_reset_at: reset_at
        })
        |> Ash.update(authorize?: false)

      assert updated.tier == "pro"
      assert updated.monthly_draw_limit == 1000
      assert updated.count_reset_at == reset_at
    end
  end

  describe "regenerate_webhook_secret" do
    test "produces a new encrypted secret and returns raw via metadata" do
      {:ok, key} = create_key()
      old_secret = key.webhook_secret

      {:ok, updated} =
        key
        |> Ash.Changeset.for_update(:regenerate_webhook_secret, %{})
        |> Ash.update(authorize?: false)

      assert updated.webhook_secret != old_secret
      assert updated.__metadata__.raw_webhook_secret != nil
      assert byte_size(updated.__metadata__.raw_webhook_secret) > 0
    end

    test "new secret decrypts successfully" do
      {:ok, key} = create_key()

      {:ok, updated} =
        key
        |> Ash.Changeset.for_update(:regenerate_webhook_secret, %{})
        |> Ash.update(authorize?: false)

      {:ok, decrypted} =
        updated.webhook_secret
        |> Base.decode64!()
        |> WallopCore.Vault.decrypt()

      assert decrypted == updated.__metadata__.raw_webhook_secret
    end

    test "old secret no longer matches after regeneration" do
      {:ok, key} = create_key()
      original_raw = key.__metadata__.raw_webhook_secret

      {:ok, updated} =
        key
        |> Ash.Changeset.for_update(:regenerate_webhook_secret, %{})
        |> Ash.update(authorize?: false)

      assert updated.__metadata__.raw_webhook_secret != original_raw
    end
  end

  test "the draw counting actions are gone" do
    for action <- [:increment_draw_count, :reset_draw_count] do
      assert Info.action(ApiKey, action) == nil
    end
  end
end
