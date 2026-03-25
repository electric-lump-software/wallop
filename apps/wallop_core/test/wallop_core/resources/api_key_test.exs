defmodule WallopCore.Resources.ApiKeyTest do
  use WallopCore.DataCase, async: true

  alias WallopCore.Resources.ApiKey

  defp create_key(name \\ "test key") do
    ApiKey
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create()
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
        |> Ash.update()

      assert deactivated.active == false
      assert deactivated.deactivated_at != nil
    end
  end
end
