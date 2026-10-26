defmodule WallopCore.KeyRotationTest do
  use WallopCore.DataCase, async: false

  import ExUnit.CaptureIO
  import WallopCore.TestHelpers

  require Ash.Query

  alias WallopCore.{KeyRotation, OperatorInfo, Protocol}

  alias WallopCore.Resources.{
    ExecutionReceipt,
    InfrastructureSigningKey,
    OperatorReceipt,
    OperatorSigningKey,
    TransparencyAnchor
  }

  defp quietly(fun) do
    {result, _output} = with_io(fun)
    result
  end

  defp rotate_infra!, do: quietly(&KeyRotation.rotate_infrastructure_key/0) |> ok!()

  defp rotate_operator!(operator),
    do: quietly(fn -> KeyRotation.rotate_operator_key(to_string(operator.slug)) end) |> ok!()

  defp ok!({:ok, value}), do: value

  defp infra_key_ids do
    InfrastructureSigningKey |> Ash.read!(authorize?: false) |> Enum.map(& &1.key_id)
  end

  defp operator_keys(operator_id) do
    OperatorSigningKey
    |> Ash.Query.filter(operator_id == ^operator_id)
    |> Ash.read!(authorize?: false)
  end

  defp operator_key(operator_id, key_id) do
    Enum.find(operator_keys(operator_id), &(&1.key_id == key_id))
  end

  defp infra_key(key_id) do
    InfrastructureSigningKey
    |> Ash.Query.filter(key_id == ^key_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp lock_receipt(draw) do
    OperatorReceipt |> Ash.Query.filter(draw_id == ^draw.id) |> Ash.read_one!(authorize?: false)
  end

  defp execution_receipt(draw) do
    ExecutionReceipt |> Ash.Query.filter(draw_id == ^draw.id) |> Ash.read_one!(authorize?: false)
  end

  describe "rotate_infrastructure_key/0" do
    test "adds a key that becomes the current key and prints only its id and public key" do
      old = create_infrastructure_key()

      output =
        capture_io(fn ->
          assert {:ok, %{key_id: key_id, public_key_hex: hex}} =
                   KeyRotation.rotate_infrastructure_key()

          send(self(), {:new, key_id, hex})
        end)

      assert_received {:new, key_id, hex}
      assert {:ok, %{key_id: ^key_id}} = KeyRotation.current_infrastructure_key()
      assert Enum.sort(infra_key_ids()) == Enum.sort([old.key_id, key_id])
      assert output =~ key_id
      assert output =~ hex
      refute output =~ "private"
    end

    test "refuses when no infrastructure key exists yet" do
      assert {:error, :no_infrastructure_key} = KeyRotation.rotate_infrastructure_key()
      assert infra_key_ids() == []
    end
  end

  describe "rotate_operator_key/1" do
    test "adds a key to the existing operator" do
      operator = create_operator()
      [old] = operator_keys(operator.id)

      %{key_id: new_id} = rotate_operator!(operator)

      assert Enum.sort(Enum.map(operator_keys(operator.id), & &1.key_id)) ==
               Enum.sort([old.key_id, new_id])
    end

    test "refuses an unknown slug" do
      assert {:error, :operator_not_found} = KeyRotation.rotate_operator_key("no-such-operator")
    end
  end

  describe "revoke_superseded_keys/0" do
    test "after rotation, leaves exactly one infrastructure key and one key per operator" do
      create_infrastructure_key()
      a = create_operator()
      b = create_operator()

      %{key_id: infra_new} = rotate_infra!()
      %{key_id: a_new} = rotate_operator!(a)
      %{key_id: b_new} = rotate_operator!(b)

      assert {:ok, %{count: 3, infrastructure: [_], operator: revoked_operator_keys}} =
               KeyRotation.revoke_superseded_keys()

      assert length(revoked_operator_keys) == 2
      assert infra_key_ids() == [infra_new]
      assert Enum.map(operator_keys(a.id), & &1.key_id) == [a_new]
      assert Enum.map(operator_keys(b.id), & &1.key_id) == [b_new]
    end

    test "never revokes a current key: a single key survives, and a second run revokes nothing" do
      infra = create_infrastructure_key()
      operator = create_operator()
      [op_key] = operator_keys(operator.id)

      assert {:ok, %{count: 0}} = KeyRotation.revoke_superseded_keys()
      assert {:ok, %{count: 0}} = KeyRotation.revoke_superseded_keys()

      assert infra_key_ids() == [infra.key_id]
      assert Enum.map(operator_keys(operator.id), & &1.key_id) == [op_key.key_id]
    end

    test "leaves an operator whose only key is not yet valid alone" do
      operator = create_operator()
      [current] = operator_keys(operator.id)
      revoke_key!(current)

      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, encrypted} = WallopCore.Vault.encrypt(private_key)

      OperatorSigningKey
      |> Ash.Changeset.for_create(:create, %{
        operator_id: operator.id,
        key_id: Protocol.key_id(public_key),
        public_key: public_key,
        private_key: encrypted,
        valid_from: DateTime.add(DateTime.utc_now(), 30, :second)
      })
      |> Ash.create!(authorize?: false)

      assert {:ok, %{count: 0}} = KeyRotation.revoke_superseded_keys()
      assert [_pending] = operator_keys(operator.id)
    end

    test "a lock after revocation signs with the new key" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      %{key_id: new_id} = rotate_operator!(operator)
      {:ok, _} = KeyRotation.revoke_superseded_keys()

      draw = create_draw(api_key)

      assert lock_receipt(draw).signing_key_id == new_id
    end
  end

  describe "the table" do
    setup do
      create_infrastructure_key()
      operator = create_operator()
      rotate_operator!(operator)
      {:ok, %{count: 1}} = KeyRotation.revoke_superseded_keys()
      :ok
    end

    for {op, sql} <- [
          {"UPDATE", "UPDATE signing_key_revocations SET reason = 'x'"},
          {"DELETE", "DELETE FROM signing_key_revocations"},
          {"TRUNCATE", "TRUNCATE signing_key_revocations"}
        ] do
      test "refuses #{op}" do
        assert_raise Postgrex.Error, ~r/signing_key_revocations is append-only/, fn ->
          WallopCore.Repo.query!(unquote(sql))
        end
      end
    end
  end

  describe "a revoked key is excluded from" do
    test "the current operator key used to sign a lock" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      [old] = operator_keys(operator.id)
      %{key_id: new_id} = rotate_operator!(operator)
      revoke_key!(operator_key(operator.id, new_id))

      draw = create_draw(api_key)

      assert lock_receipt(draw).signing_key_id == old.key_id
    end

    test "the current infrastructure key used to sign an execution" do
      old = create_infrastructure_key()
      %{key_id: new_id} = rotate_infra!()
      revoke_key!(infra_key(new_id))

      api_key = create_api_key()
      draw = api_key |> create_draw() |> execute_draw(test_seed(), api_key)

      assert execution_receipt(draw).signing_key_id == old.key_id
    end

    test "OperatorInfo.signing_keys_hex/2, for both receipts" do
      create_infrastructure_key()
      api_key = create_api_key()
      draw = api_key |> create_draw() |> execute_draw(test_seed(), api_key)
      lock = lock_receipt(draw)
      execution = execution_receipt(draw)

      assert {op_hex, infra_hex} = OperatorInfo.signing_keys_hex(lock, execution)
      assert is_binary(op_hex) and is_binary(infra_hex)

      revoke_key!(operator_key(lock.operator_id, lock.signing_key_id))
      assert {nil, ^infra_hex} = OperatorInfo.signing_keys_hex(lock, execution)

      revoke_key!(infra_key(execution.signing_key_id))
      assert {nil, nil} = OperatorInfo.signing_keys_hex(lock, execution)
    end

    test "the transparency anchor's signature validation" do
      key = create_infrastructure_key()
      {:ok, private_key} = WallopCore.Vault.decrypt(key.private_key)
      merkle_root = :crypto.hash(:sha256, "anchor-after-revocation")
      revoke_key!(key)

      attrs = %{
        merkle_root: merkle_root,
        receipt_count: 0,
        to_receipt_id: Ecto.UUID.generate(),
        anchored_at: DateTime.utc_now(),
        operator_receipts_root: :crypto.hash(:sha256, <<>>),
        execution_receipts_root: :crypto.hash(:sha256, <<>>),
        execution_receipt_count: 0,
        infrastructure_signature: Protocol.sign_receipt(merkle_root, private_key),
        signing_key_id: key.key_id
      }

      assert {:error, %Ash.Error.Invalid{}} =
               TransparencyAnchor
               |> Ash.Changeset.for_create(:create, attrs)
               |> Ash.create(authorize?: false)
    end
  end

  describe "revocation is per operator" do
    test "revoking one operator's key_id leaves another operator's key with the same key_id" do
      a = create_operator()
      b = create_operator()
      [a_key] = operator_keys(a.id)
      b_twin = insert_operator_key_with_id!(b, a_key.key_id)

      revoke_key!(a_key)

      assert operator_keys(a.id) == []
      assert Enum.map(operator_keys(b.id), & &1.id) |> Enum.member?(b_twin.id)
    end
  end

  describe "OperatorInfo.signing_keys_hex/2" do
    test "resolves the lock receipt's key within its own operator" do
      create_infrastructure_key()
      api_key = create_api_key()
      draw = api_key |> create_draw() |> execute_draw(test_seed(), api_key)
      lock = lock_receipt(draw)
      own = operator_key(lock.operator_id, lock.signing_key_id)

      other = create_operator()
      insert_operator_key_with_id!(other, lock.signing_key_id)

      assert {op_hex, _} = OperatorInfo.signing_keys_hex(lock, nil)
      assert op_hex == Base.encode16(own.public_key, case: :lower)

      revoke_key!(own)
      assert {nil, nil} = OperatorInfo.signing_keys_hex(lock, nil)
    end
  end

  defp insert_operator_key_with_id!(operator, key_id) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, encrypted} = WallopCore.Vault.encrypt(private_key)

    OperatorSigningKey
    |> Ash.Changeset.for_create(:create, %{
      operator_id: operator.id,
      key_id: key_id,
      public_key: public_key,
      private_key: encrypted,
      valid_from: DateTime.add(DateTime.utc_now(), -40, :second)
    })
    |> Ash.create!(authorize?: false)
  end
end
