defmodule WallopCore.Resources.OperatorTest do
  use WallopCore.DataCase, async: true

  alias WallopCore.Resources.{Operator, OperatorReceipt, OperatorSigningKey}

  describe "create" do
    test "creates an operator with a slug and name" do
      {:ok, op} =
        Operator
        |> Ash.Changeset.for_create(:create, %{slug: "acme-prizes", name: "Acme"})
        |> Ash.create()

      assert to_string(op.slug) == "acme-prizes"
      assert op.name == "Acme"
    end

    test "rejects reserved slugs" do
      assert {:error, %Ash.Error.Invalid{}} =
               Operator
               |> Ash.Changeset.for_create(:create, %{slug: "admin", name: "x"})
               |> Ash.create()
    end

    test "rejects bad slug formats" do
      for bad <- ["A", "a", "with space", "-leading", "trailing-", "TooLong" <> String.duplicate("a", 64)] do
        assert {:error, _} =
                 Operator
                 |> Ash.Changeset.for_create(:create, %{slug: bad, name: "x"})
                 |> Ash.create()
      end
    end

    test "enforces unique slug" do
      _ = create_operator("dup-slug")

      assert {:error, _} =
               Operator
               |> Ash.Changeset.for_create(:create, %{slug: "dup-slug", name: "y"})
               |> Ash.create()
    end
  end

  describe "signing key immutability" do
    test "operator_signing_keys cannot be UPDATEd via SQL" do
      operator = create_operator()

      assert_raise Postgrex.Error, ~r/operator_signing_keys is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE operator_signing_keys SET key_id = 'x' WHERE operator_id = $1",
          [Ecto.UUID.dump!(operator.id)]
        )
      end
    end

    test "operator_signing_keys cannot be DELETEd via SQL" do
      operator = create_operator()

      assert_raise Postgrex.Error, ~r/operator_signing_keys is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM operator_signing_keys WHERE operator_id = $1",
          [Ecto.UUID.dump!(operator.id)]
        )
      end
    end
  end

  describe "lock signs and stores a receipt for operator-bound api_keys" do
    test "creates a receipt row in the same transaction as lock" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)

      draw = create_draw(api_key)

      assert draw.operator_id == operator.id
      assert draw.operator_sequence == 1

      [receipt] =
        OperatorReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      assert receipt.sequence == 1
      assert receipt.entry_hash == draw.entry_hash
      assert byte_size(receipt.signature) == 64

      [signing_key] =
        OperatorSigningKey
        |> Ash.Query.filter(operator_id == ^operator.id)
        |> Ash.read!(authorize?: false)

      assert WallopCore.Protocol.verify_receipt(
               receipt.payload_jcs,
               receipt.signature,
               signing_key.public_key
             )
    end

    test "lock without an operator does not create a receipt (backward compat)" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.operator_id == nil
      assert draw.operator_sequence == nil

      [] =
        OperatorReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)
    end

    test "operator_receipts cannot be UPDATEd or DELETEd via SQL" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)

      assert_raise Postgrex.Error, ~r/operator_receipts is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE operator_receipts SET sequence = 999 WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end

      assert_raise Postgrex.Error, ~r/operator_receipts is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM operator_receipts WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  describe "operator_sequence assignment" do
    test "increments per-operator and is gap-free across multiple draws" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)

      d1 = create_draw(api_key)
      d2 = create_draw(api_key)
      d3 = create_draw(api_key)

      assert {d1.operator_sequence, d2.operator_sequence, d3.operator_sequence} == {1, 2, 3}
    end

    test "is isolated between operators" do
      op_a = create_operator("op-a-#{:rand.uniform(1_000_000)}")
      op_b = create_operator("op-b-#{:rand.uniform(1_000_000)}")
      key_a = create_api_key_for_operator(op_a)
      key_b = create_api_key_for_operator(op_b)

      d_a1 = create_draw(key_a)
      d_b1 = create_draw(key_b)
      d_a2 = create_draw(key_a)

      assert d_a1.operator_sequence == 1
      assert d_b1.operator_sequence == 1
      assert d_a2.operator_sequence == 2
    end
  end

  describe "sensitive private_key" do
    test "is not exposed in inspect output" do
      operator = create_operator()

      [key] =
        OperatorSigningKey
        |> Ash.Query.filter(operator_id == ^operator.id)
        |> Ash.read!(authorize?: false)

      refute inspect(key) =~ Base.encode16(key.private_key, case: :lower)
    end
  end

  require Ash.Query
end
