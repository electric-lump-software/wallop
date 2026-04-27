defmodule WallopCore.Resources.OperatorSigningKeyTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Protocol
  alias WallopCore.Resources.OperatorSigningKey

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
end
