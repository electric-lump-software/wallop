defmodule WallopCore.DbImmutabilityTest do
  @moduledoc """
  Schema-level enforcement tests for the trigger / constraint hardening
  added in `20260409000000_db_level_immutability_hardening.exs`.

  These tests bypass Ash entirely and write directly via the repo, so they
  exercise the Postgres trigger/constraint layer rather than the Ash policy
  layer (which is covered by `policy_hardening_test.exs`). The point is
  that even if every Ash policy were removed tomorrow, Postgres would
  still refuse the forbidden writes.

  The legitimate `session_replication_role = 'replica'` bypass is also
  exercised — this is the documented escape hatch for one-off
  interventions and should remain functional.
  """
  use WallopCore.DataCase, async: false

  require Ash.Query
  import WallopCore.TestHelpers

  alias WallopCore.Repo
  alias WallopCore.Resources.OperatorSigningKey

  describe "operator_signing_keys: signing_key_immutability trigger" do
    test "direct UPDATE on a signing key row raises" do
      operator = create_operator()
      [key | _] = list_signing_keys(operator.id)

      assert_raise Postgrex.Error, ~r/operator_signing_keys is append-only/, fn ->
        Repo.query!(
          "UPDATE operator_signing_keys SET key_id = 'tampered' WHERE id = $1",
          [Ecto.UUID.dump!(key.id)]
        )
      end
    end

    test "direct DELETE of a signing key row raises" do
      operator = create_operator()
      [key | _] = list_signing_keys(operator.id)

      assert_raise Postgrex.Error, ~r/operator_signing_keys is append-only/, fn ->
        Repo.query!(
          "DELETE FROM operator_signing_keys WHERE id = $1",
          [Ecto.UUID.dump!(key.id)]
        )
      end
    end

    test "INSERT (the legitimate happy path) still works" do
      operator = create_operator()
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, encrypted} = WallopCore.Vault.encrypt(private_key)

      assert {:ok, _} =
               OperatorSigningKey
               |> Ash.Changeset.for_create(:create, %{
                 operator_id: operator.id,
                 key_id: "second",
                 public_key: public_key,
                 private_key: encrypted,
                 valid_from: DateTime.utc_now()
               })
               |> Ash.create(authorize?: false)
    end

    test "session_replication_role bypass succeeds (documented escape hatch)" do
      operator = create_operator()
      [key | _] = list_signing_keys(operator.id)

      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = 'replica'")

        assert {:ok, _} =
                 Repo.query(
                   "UPDATE operator_signing_keys SET key_id = 'patched' WHERE id = $1",
                   [Ecto.UUID.dump!(key.id)]
                 )
      end)
    end

    defp list_signing_keys(operator_id) do
      OperatorSigningKey
      |> Ash.Query.filter(operator_id == ^operator_id)
      |> Ash.read!(authorize?: false)
    end
  end

  describe "operators: operator_slug_immutability trigger" do
    test "direct UPDATE that changes slug raises" do
      operator = create_operator()

      assert_raise Postgrex.Error, ~r/operators.slug is immutable/, fn ->
        Repo.query!(
          "UPDATE operators SET slug = 'hijacked-slug' WHERE id = $1",
          [Ecto.UUID.dump!(operator.id)]
        )
      end
    end

    test "direct UPDATE that changes name (not slug) succeeds" do
      operator = create_operator()

      assert {:ok, _} =
               Repo.query(
                 "UPDATE operators SET name = 'New Display Name' WHERE id = $1",
                 [Ecto.UUID.dump!(operator.id)]
               )
    end

    test "session_replication_role bypass allows slug change (escape hatch)" do
      operator = create_operator()

      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = 'replica'")

        assert {:ok, _} =
                 Repo.query(
                   "UPDATE operators SET slug = 'renamed-by-admin' WHERE id = $1",
                   [Ecto.UUID.dump!(operator.id)]
                 )
      end)
    end
  end

  describe "api_keys: api_keys_key_hash_format CHECK constraint" do
    test "INSERT with a valid bcrypt hash succeeds" do
      api_key = create_api_key()
      assert is_binary(api_key.key_hash)
      assert api_key.key_hash =~ ~r/^\$2[aby]\$[0-9]{2}\$.{53}$/
    end

    test "direct UPDATE setting key_hash to garbage raises" do
      api_key = create_api_key()

      assert_raise Postgrex.Error, ~r/api_keys_key_hash_format/, fn ->
        Repo.query!(
          "UPDATE api_keys SET key_hash = 'definitely not a bcrypt hash' WHERE id = $1",
          [Ecto.UUID.dump!(api_key.id)]
        )
      end
    end

    test "direct UPDATE setting key_hash to empty raises" do
      api_key = create_api_key()

      assert_raise Postgrex.Error, ~r/api_keys_key_hash_format/, fn ->
        Repo.query!(
          "UPDATE api_keys SET key_hash = '' WHERE id = $1",
          [Ecto.UUID.dump!(api_key.id)]
        )
      end
    end

    test "direct UPDATE setting key_hash to a different valid bcrypt hash succeeds" do
      api_key = create_api_key()
      replacement = "$2b$04$" <> String.duplicate("a", 53)

      assert {:ok, _} =
               Repo.query(
                 "UPDATE api_keys SET key_hash = $2 WHERE id = $1",
                 [Ecto.UUID.dump!(api_key.id), replacement]
               )
    end
  end
end
