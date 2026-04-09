defmodule WallopCore.Transparency.AnchorWorkerTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers
  require Ash.Query

  alias WallopCore.Protocol
  alias WallopCore.Resources.{ExecutionReceipt, OperatorReceipt, TransparencyAnchor}
  alias WallopCore.Transparency.AnchorWorker

  describe "dual sub-tree anchor" do
    setup do
      infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)

      # Create and execute a draw — produces both operator receipt (at lock)
      # and execution receipt (at execute)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      %{infra_key: infra_key, operator: operator, draw: executed}
    end

    test "creates an anchor with dual sub-trees and combined root", %{draw: _draw} do
      {:ok, anchor} = perform_anchor()

      assert anchor.receipt_count == 1
      assert anchor.execution_receipt_count == 1
      assert byte_size(anchor.merkle_root) == 32
      assert byte_size(anchor.operator_receipts_root) == 32
      assert byte_size(anchor.execution_receipts_root) == 32

      # Verify via the public combined_root/2 function
      expected =
        AnchorWorker.combined_root(
          anchor.operator_receipts_root,
          anchor.execution_receipts_root
        )

      assert anchor.merkle_root == expected
    end

    test "combined root uses distinct domain prefix from Merkle internal nodes" do
      # The anchor root prefix must NOT be <<1>> (internal node) or <<0>> (leaf)
      # to avoid structural ambiguity with RFC 6962 tree hashes.
      dummy_root = :crypto.hash(:sha256, "test")
      combined = AnchorWorker.combined_root(dummy_root, dummy_root)
      internal_node = :crypto.hash(:sha256, <<1>> <> dummy_root <> dummy_root)

      refute combined == internal_node
    end

    test "sub-tree roots match independent Merkle computations with length-prefixed leaves",
         %{draw: draw} do
      [op_receipt] =
        OperatorReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      [exec_receipt] =
        ExecutionReceipt
        |> Ash.Query.filter(draw_id == ^draw.id)
        |> Ash.read!(authorize?: false)

      {:ok, anchor} = perform_anchor()

      # Leaves are length-prefixed: <<payload_len::32>> <> payload_jcs <> signature
      op_leaf =
        <<byte_size(op_receipt.payload_jcs)::32>> <>
          op_receipt.payload_jcs <> op_receipt.signature

      exec_leaf =
        <<byte_size(exec_receipt.payload_jcs)::32>> <>
          exec_receipt.payload_jcs <> exec_receipt.signature

      assert anchor.operator_receipts_root == Protocol.merkle_root([op_leaf])
      assert anchor.execution_receipts_root == Protocol.merkle_root([exec_leaf])
    end

    test "infrastructure signature verifies under the infra public key", %{
      infra_key: infra_key
    } do
      {:ok, anchor} = perform_anchor()

      assert byte_size(anchor.infrastructure_signature) == 64
      assert anchor.signing_key_id == infra_key.key_id

      assert Protocol.verify_receipt(
               anchor.merkle_root,
               anchor.infrastructure_signature,
               infra_key.public_key
             )
    end

    test "infrastructure signature does NOT verify under a different key" do
      {:ok, anchor} = perform_anchor()
      {wrong_pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)

      refute Protocol.verify_receipt(
               anchor.merkle_root,
               anchor.infrastructure_signature,
               wrong_pub
             )
    end

    test "anchor includes drand evidence" do
      {:ok, anchor} = perform_anchor()

      # Drand fetch may fail in test (no network), but the fields should be set
      # to either valid values or nil
      assert anchor.external_anchor_kind in ["drand_quicknet", nil]
    end

    test "anchored_at is derived from latest receipt, not wall clock" do
      {:ok, anchor} = perform_anchor()

      # anchored_at should equal the latest receipt's inserted_at,
      # not a DateTime.utc_now() call
      all_receipts =
        Ash.read!(OperatorReceipt, authorize?: false) ++
          Ash.read!(ExecutionReceipt, authorize?: false)

      latest = Enum.max_by(all_receipts, & &1.inserted_at, DateTime)
      assert anchor.anchored_at == latest.inserted_at
    end
  end

  describe "idempotence" do
    setup do
      _infra_key = create_infrastructure_key()
      %{}
    end

    test "no receipts produces no anchor" do
      assert :ok = perform_anchor_raw()

      [] = Ash.read!(TransparencyAnchor, authorize?: false)
    end

    test "second run with no new receipts produces no additional anchor" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      _executed = execute_draw(draw, test_seed(), api_key)

      {:ok, _} = perform_anchor()
      :ok = perform_anchor_raw()

      anchors = Ash.read!(TransparencyAnchor, authorize?: false)
      assert length(anchors) == 1
    end
  end

  describe "operator-only receipts (backward compat)" do
    setup do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)

      # Lock a draw (produces operator receipt) but don't execute it
      # (no execution receipt)
      draw = create_draw(api_key)

      %{draw: draw}
    end

    test "anchor works with operator receipts only", %{draw: _draw} do
      {:ok, anchor} = perform_anchor()

      assert anchor.receipt_count == 1
      assert anchor.execution_receipt_count == 0
      assert byte_size(anchor.operator_receipts_root) == 32
      assert byte_size(anchor.execution_receipts_root) == 32

      # Execution receipts root is the empty-tree sentinel
      assert anchor.execution_receipts_root == Protocol.merkle_root([])
    end
  end

  describe "multiple draws across anchors" do
    setup do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      %{operator: operator, api_key: api_key}
    end

    test "second anchor only includes new receipts", %{api_key: api_key} do
      # First draw + anchor
      _d1 = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))
      {:ok, anchor1} = perform_anchor()

      assert anchor1.receipt_count == 1
      assert anchor1.execution_receipt_count == 1

      # Second draw + anchor
      _d2 = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))
      {:ok, anchor2} = perform_anchor()

      assert anchor2.receipt_count == 1
      assert anchor2.execution_receipt_count == 1

      # Roots should differ (different receipts)
      refute anchor1.merkle_root == anchor2.merkle_root
    end
  end

  describe "no infrastructure key" do
    test "anchor fails when infra key is missing (Oban will retry)" do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      _draw = create_draw(api_key)

      assert {:error, _} = perform_anchor()

      # No anchor created
      [] = Ash.read!(TransparencyAnchor, authorize?: false)
    end
  end

  describe "anchor immutability" do
    setup do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      _draw = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))
      {:ok, anchor} = perform_anchor()
      %{anchor: anchor}
    end

    test "cannot UPDATE via raw SQL", %{anchor: anchor} do
      assert_raise Postgrex.Error, ~r/transparency_anchors is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE transparency_anchors SET receipt_count = 999 WHERE id = $1",
          [Ecto.UUID.dump!(anchor.id)]
        )
      end
    end

    test "cannot DELETE via raw SQL", %{anchor: anchor} do
      assert_raise Postgrex.Error, ~r/transparency_anchors is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM transparency_anchors WHERE id = $1",
          [Ecto.UUID.dump!(anchor.id)]
        )
      end
    end
  end

  # Helpers

  defp perform_anchor do
    case AnchorWorker.perform(%Oban.Job{}) do
      {:ok, anchor} -> {:ok, anchor}
      {:error, reason} -> {:error, reason}
      :ok -> :ok
    end
  end

  defp perform_anchor_raw do
    case AnchorWorker.perform(%Oban.Job{}) do
      {:ok, _} -> :ok
      {:error, _} -> :error
      :ok -> :ok
    end
  end
end
