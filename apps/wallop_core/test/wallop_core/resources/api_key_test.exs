defmodule WallopCore.Resources.ApiKeyTest do
  use WallopCore.DataCase, async: true

  import WallopCore.TestHelpers, only: [create_api_key: 0, create_api_key: 1]

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

    test "accepts rate_limit_per_minute" do
      assert create_api_key(%{rate_limit_per_minute: 300}).rate_limit_per_minute == 300
    end

    test "no longer accepts the old quota fields" do
      for input <- [
            %{tier: "pro"},
            %{monthly_draw_limit: 10},
            %{count_reset_at: DateTime.utc_now()}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 ApiKey
                 |> Ash.Changeset.for_create(:create, Map.put(input, :name, "k"))
                 |> Ash.create(authorize?: false)
      end
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

  describe "set_rate_limit" do
    test "sets the per-minute limit" do
      key = create_api_key()

      updated =
        key
        |> Ash.Changeset.for_update(:set_rate_limit, %{rate_limit_per_minute: 300})
        |> Ash.update!(authorize?: false)

      assert updated.rate_limit_per_minute == 300
    end

    test "never writes tier or the other old quota columns" do
      key = create_api_key()

      for input <- [
            %{tier: "pro"},
            %{monthly_draw_limit: 10},
            %{monthly_draw_count: 0},
            %{count_reset_at: DateTime.utc_now()}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 key
                 |> Ash.Changeset.for_update(
                   :set_rate_limit,
                   Map.put(input, :rate_limit_per_minute, 300)
                 )
                 |> Ash.update(authorize?: false)
      end

      reloaded = Ash.get!(ApiKey, key.id, authorize?: false)
      assert reloaded.tier == nil
      assert reloaded.rate_limit_per_minute == nil
    end

    test "rejects a per-minute limit outside 1..6000" do
      key = create_api_key()

      for value <- [0, 6001] do
        assert {:error, %Ash.Error.Invalid{}} =
                 key
                 |> Ash.Changeset.for_update(:set_rate_limit, %{rate_limit_per_minute: value})
                 |> Ash.update(authorize?: false)
      end
    end

    test "update_tier is gone" do
      assert Info.action(ApiKey, :update_tier) == nil
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
