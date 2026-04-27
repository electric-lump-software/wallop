defmodule WallopCore.Resources.OperatorSigningKeyTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Protocol
  alias WallopCore.Resources.OperatorSigningKey

  require Ash.Query

  describe "valid_from temporal binding (CHECK constraint)" do
    setup do
      operator = create_operator()
      %{operator: operator}
    end

    test "rejects backdated valid_from outside ±60s window", %{operator: operator} do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, encrypted} = WallopCore.Vault.encrypt(priv)

      assert_raise Ash.Error.Unknown, ~r/valid_from_within_skew/, fn ->
        OperatorSigningKey
        |> Ash.Changeset.for_create(:create, %{
          operator_id: operator.id,
          key_id: Protocol.key_id(pub),
          public_key: pub,
          private_key: encrypted,
          valid_from: DateTime.add(DateTime.utc_now(), -120, :second)
        })
        |> Ash.create!(authorize?: false)
      end
    end

    test "rejects forward-dated valid_from outside ±60s window", %{operator: operator} do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, encrypted} = WallopCore.Vault.encrypt(priv)

      assert_raise Ash.Error.Unknown, ~r/valid_from_within_skew/, fn ->
        OperatorSigningKey
        |> Ash.Changeset.for_create(:create, %{
          operator_id: operator.id,
          key_id: Protocol.key_id(pub),
          public_key: pub,
          private_key: encrypted,
          valid_from: DateTime.add(DateTime.utc_now(), 120, :second)
        })
        |> Ash.create!(authorize?: false)
      end
    end

    test "accepts valid_from equal to current time", %{operator: operator} do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, encrypted} = WallopCore.Vault.encrypt(priv)

      {:ok, key} =
        OperatorSigningKey
        |> Ash.Changeset.for_create(:create, %{
          operator_id: operator.id,
          key_id: Protocol.key_id(pub),
          public_key: pub,
          private_key: encrypted,
          valid_from: DateTime.utc_now()
        })
        |> Ash.create(authorize?: false)

      assert key.valid_from
    end
  end

  describe "Protocol.assert_key_consistency on a bootstrapped row" do
    test "passes for a key emitted by create_operator (standard bootstrap path)" do
      operator = create_operator()

      [key] =
        OperatorSigningKey
        |> Ash.Query.filter(operator_id == ^operator.id)
        |> Ash.read!(authorize?: false)

      {:ok, private_key} = WallopCore.Vault.decrypt(key.private_key)

      assert :ok =
               Protocol.assert_key_consistency(
                 key.public_key,
                 private_key,
                 key.key_id
               )
    end
  end
end
