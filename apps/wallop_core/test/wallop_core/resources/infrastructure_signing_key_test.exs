defmodule WallopCore.Resources.InfrastructureSigningKeyTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers
  require Ash.Query

  alias WallopCore.Protocol
  alias WallopCore.Resources.InfrastructureSigningKey

  describe "create" do
    test "creates a key with all required fields" do
      key = create_infrastructure_key()

      assert String.match?(key.key_id, ~r/^[0-9a-f]{8}$/)
      assert byte_size(key.public_key) == 32
      assert is_binary(key.private_key)
      assert %DateTime{} = key.valid_from
      assert %DateTime{} = key.inserted_at
    end

    test "key_id matches Protocol.key_id computation" do
      key = create_infrastructure_key()
      expected_id = Protocol.key_id(key.public_key)
      assert key.key_id == expected_id
    end

    test "enforces unique key_id" do
      key = create_infrastructure_key()

      assert {:error, _} =
               InfrastructureSigningKey
               |> Ash.Changeset.for_create(:create, %{
                 key_id: key.key_id,
                 public_key: :crypto.strong_rand_bytes(32),
                 private_key: :crypto.strong_rand_bytes(64),
                 valid_from: DateTime.utc_now()
               })
               |> Ash.create(authorize?: false)
    end

    test "private_key is Vault-encrypted and round-trips through decrypt" do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, encrypted} = WallopCore.Vault.encrypt(priv)

      {:ok, key} =
        InfrastructureSigningKey
        |> Ash.Changeset.for_create(:create, %{
          key_id: Protocol.key_id(pub),
          public_key: pub,
          private_key: encrypted,
          valid_from: DateTime.utc_now()
        })
        |> Ash.create(authorize?: false)

      {:ok, decrypted} = WallopCore.Vault.decrypt(key.private_key)
      assert decrypted == priv
    end
  end

  describe "immutability (DB trigger)" do
    setup do
      key = create_infrastructure_key()
      %{key: key}
    end

    test "cannot UPDATE infrastructure_signing_keys via raw SQL", %{key: key} do
      assert_raise Postgrex.Error, ~r/infrastructure_signing_keys is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE infrastructure_signing_keys SET key_id = 'tampered' WHERE id = $1",
          [Ecto.UUID.dump!(key.id)]
        )
      end
    end

    test "cannot DELETE infrastructure_signing_keys via raw SQL", %{key: key} do
      assert_raise Postgrex.Error, ~r/infrastructure_signing_keys is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM infrastructure_signing_keys WHERE id = $1",
          [Ecto.UUID.dump!(key.id)]
        )
      end
    end
  end

  describe "key ordering for rotation" do
    test "multiple keys ordered by valid_from desc gives current key first" do
      now = DateTime.utc_now()

      for offset <- [-3600, -1800, -60] do
        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
        {:ok, encrypted} = WallopCore.Vault.encrypt(priv)

        InfrastructureSigningKey
        |> Ash.Changeset.for_create(:create, %{
          key_id: Protocol.key_id(pub),
          public_key: pub,
          private_key: encrypted,
          valid_from: DateTime.add(now, offset, :second)
        })
        |> Ash.create!(authorize?: false)
      end

      keys =
        InfrastructureSigningKey
        |> Ash.Query.filter(valid_from <= ^now)
        |> Ash.Query.sort(valid_from: :desc)
        |> Ash.read!(authorize?: false)

      assert length(keys) == 3

      # Most recent valid_from should be first
      [newest | _] = keys
      valid_froms = Enum.map(keys, & &1.valid_from)
      assert valid_froms == Enum.sort(valid_froms, {:desc, DateTime})

      # The -60 second key should be the "current" key
      assert newest.valid_from == DateTime.add(now, -60, :second)
    end
  end

  describe "sensitive private_key" do
    test "is not exposed in inspect output" do
      key = create_infrastructure_key()
      inspected = inspect(key)
      refute inspected =~ Base.encode16(key.private_key, case: :lower)
    end
  end
end
