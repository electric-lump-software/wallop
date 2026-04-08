defmodule WallopCore.Resources.ApiKeyTest do
  use WallopCore.DataCase, async: true

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

  describe "increment_draw_count" do
    test "increments the count and sets reset_at on first call" do
      {:ok, key} = create_key()

      {:ok, updated} =
        key
        |> Ash.Changeset.for_update(:increment_draw_count, %{})
        |> Ash.update(authorize?: false)

      assert updated.monthly_draw_count == 1
      assert updated.count_reset_at != nil
    end

    test "increments the count without resetting if reset_at is in the future" do
      future = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)

      {:ok, key} =
        ApiKey
        |> Ash.Changeset.for_create(:create, %{name: "x", count_reset_at: future})
        |> Ash.create(authorize?: false)

      # Bump count to 5 directly
      WallopCore.Repo.query!(
        "UPDATE api_keys SET monthly_draw_count = 5 WHERE id = $1",
        [Ecto.UUID.dump!(key.id)]
      )

      key = Ash.get!(ApiKey, key.id, authorize?: false)

      {:ok, updated} =
        key
        |> Ash.Changeset.for_update(:increment_draw_count, %{})
        |> Ash.update(authorize?: false)

      assert updated.monthly_draw_count == 6
      assert DateTime.compare(updated.count_reset_at, future) == :eq
    end

    test "resets the count to 1 if reset_at is in the past" do
      past = DateTime.add(DateTime.utc_now(), -86_400, :second)

      {:ok, key} =
        ApiKey
        |> Ash.Changeset.for_create(:create, %{name: "x", count_reset_at: past})
        |> Ash.create(authorize?: false)

      WallopCore.Repo.query!(
        "UPDATE api_keys SET monthly_draw_count = 100 WHERE id = $1",
        [Ecto.UUID.dump!(key.id)]
      )

      key = Ash.get!(ApiKey, key.id, authorize?: false)

      {:ok, updated} =
        key
        |> Ash.Changeset.for_update(:increment_draw_count, %{})
        |> Ash.update(authorize?: false)

      assert updated.monthly_draw_count == 1
      assert DateTime.compare(updated.count_reset_at, DateTime.utc_now()) == :gt
    end
  end
end
