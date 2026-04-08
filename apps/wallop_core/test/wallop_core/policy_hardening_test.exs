defmodule WallopCore.PolicyHardeningTest do
  @moduledoc """
  Per-resource regression tests for the PAM-685..691 policy hardening sweep.

  Each test asserts that a previously-unguarded action is now Forbidden when
  called with a normal actor (or no actor). The legitimate `authorize?: false`
  bypass paths are exercised by the test helpers themselves and by the
  per-resource resource tests.
  """
  use WallopCore.DataCase, async: false

  require Ash.Query
  import WallopCore.TestHelpers

  alias WallopCore.Resources.{
    ApiKey,
    Draw,
    Entry,
    Operator,
    OperatorReceipt,
    OperatorSigningKey,
    TransparencyAnchor
  }

  describe "PAM-685: Draw.expire" do
    test "is Forbidden for any actor" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert_raise Ash.Error.Forbidden, fn ->
        draw
        |> Ash.Changeset.for_update(:expire, %{}, actor: api_key)
        |> Ash.update!()
      end
    end
  end

  describe "PAM-686: OperatorSigningKey" do
    test "create is Forbidden without authorize?: false" do
      operator = create_operator()
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, encrypted} = WallopCore.Vault.encrypt(private_key)

      assert_raise Ash.Error.Forbidden, fn ->
        OperatorSigningKey
        |> Ash.Changeset.for_create(:create, %{
          operator_id: operator.id,
          key_id: "deadbeef",
          public_key: public_key,
          private_key: encrypted,
          valid_from: DateTime.utc_now()
        })
        |> Ash.create!()
      end
    end
  end

  describe "PAM-687: OperatorReceipt" do
    test "create is Forbidden without authorize?: false" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)

      assert_raise Ash.Error.Forbidden, fn ->
        OperatorReceipt
        |> Ash.Changeset.for_create(:create, %{
          operator_id: operator.id,
          draw_id: draw.id,
          sequence: 999_999,
          commitment_hash: "garbage",
          entry_hash: "garbage",
          locked_at: DateTime.utc_now(),
          signing_key_id: "garbage",
          payload_jcs: <<>>,
          signature: <<0::512>>
        })
        |> Ash.create!()
      end
    end
  end

  describe "PAM-688: Operator" do
    test "create is Forbidden without authorize?: false" do
      assert_raise Ash.Error.Forbidden, fn ->
        Operator
        |> Ash.Changeset.for_create(:create, %{slug: "rogue-#{:rand.uniform(1_000_000)}", name: "Rogue"})
        |> Ash.create!()
      end
    end

    test "update_name is Forbidden for an actor that doesn't own the operator" do
      operator = create_operator()
      other_op = create_operator()
      stranger_key = create_api_key_for_operator(other_op)

      assert_raise Ash.Error.Forbidden, fn ->
        operator
        |> Ash.Changeset.for_update(:update_name, %{name: "Hijacked"}, actor: stranger_key)
        |> Ash.update!()
      end
    end

    test "update_name is Forbidden with no actor" do
      operator = create_operator()

      assert_raise Ash.Error.Forbidden, fn ->
        operator
        |> Ash.Changeset.for_update(:update_name, %{name: "Anonymous"})
        |> Ash.update!()
      end
    end
  end

  describe "PAM-689: ApiKey" do
    test "create is Forbidden without authorize?: false" do
      assert_raise Ash.Error.Forbidden, fn ->
        ApiKey
        |> Ash.Changeset.for_create(:create, %{name: "rogue", tier: "enterprise", monthly_draw_limit: 9_999_999})
        |> Ash.create!()
      end
    end

    test "set_operator is Forbidden" do
      api_key = create_api_key()
      operator = create_operator()

      assert_raise Ash.Error.Forbidden, fn ->
        api_key
        |> Ash.Changeset.for_update(:set_operator, %{operator_id: operator.id})
        |> Ash.update!()
      end
    end

    test "deactivate is Forbidden" do
      api_key = create_api_key()

      assert_raise Ash.Error.Forbidden, fn ->
        api_key
        |> Ash.Changeset.for_update(:deactivate, %{})
        |> Ash.update!()
      end
    end

    test "update_tier is Forbidden" do
      api_key = create_api_key()

      assert_raise Ash.Error.Forbidden, fn ->
        api_key
        |> Ash.Changeset.for_update(:update_tier, %{tier: "enterprise", monthly_draw_limit: 999_999})
        |> Ash.update!()
      end
    end

    test "increment_draw_count is Forbidden without authorize?: false" do
      api_key = create_api_key()

      assert_raise Ash.Error.Forbidden, fn ->
        api_key
        |> Ash.Changeset.for_update(:increment_draw_count, %{})
        |> Ash.update!()
      end
    end
  end

  describe "PAM-690: Entry" do
    test "direct create is Forbidden" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert_raise Ash.Error.Forbidden, fn ->
        Entry
        |> Ash.Changeset.for_create(:create, %{
          draw_id: draw.id,
          entry_id: "stuffed",
          weight: 1
        })
        |> Ash.create!()
      end
    end

    test "direct destroy is Forbidden" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      [entry | _] =
        WallopCore.Resources.Entry
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      assert_raise Ash.Error.Forbidden, fn ->
        entry
        |> Ash.Changeset.for_destroy(:destroy)
        |> Ash.destroy!(actor: api_key)
      end
    end
  end

  describe "PAM-691: TransparencyAnchor" do
    test "create is Forbidden without authorize?: false" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)

      receipt =
        WallopCore.Resources.OperatorReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read_one!(authorize?: false)

      assert_raise Ash.Error.Forbidden, fn ->
        TransparencyAnchor
        |> Ash.Changeset.for_create(:create, %{
          merkle_root: <<0::256>>,
          receipt_count: 999_999,
          from_receipt_id: nil,
          to_receipt_id: receipt.id,
          external_anchor_kind: "drand_quicknet",
          external_anchor_evidence: "9999999",
          anchored_at: DateTime.utc_now()
        })
        |> Ash.create!()
      end
    end
  end

  describe "happy paths still work via authorize?: false" do
    test "ApiKey create works with authorize?: false" do
      assert {:ok, _} =
               ApiKey
               |> Ash.Changeset.for_create(:create, %{name: "internal"})
               |> Ash.create(authorize?: false)
    end

    test "Operator create works with authorize?: false" do
      assert {:ok, _} =
               Operator
               |> Ash.Changeset.for_create(:create, %{slug: "happy-#{:rand.uniform(1_000_000)}", name: "Happy"})
               |> Ash.create(authorize?: false)
    end

    test "Draw.expire works with authorize?: false (ExpiryWorker path)" do
      api_key = create_api_key()
      draw = Draw
             |> Ash.Changeset.for_create(:create, %{name: "abandon", winner_count: 1}, actor: api_key)
             |> Ash.create!()

      assert {:ok, expired} =
               draw
               |> Ash.Changeset.for_update(:expire, %{})
               |> Ash.update(authorize?: false)

      assert expired.status == :expired
    end
  end
end
