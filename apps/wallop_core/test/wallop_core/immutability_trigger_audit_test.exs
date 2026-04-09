defmodule WallopCore.ImmutabilityTriggerAuditTest do
  @moduledoc """
  Comprehensive immutability trigger verification.

  Tests every forbidden transition on every protected table via raw SQL,
  confirming that DB-level triggers are the last line of defence. Ash
  policies are defence in depth; these triggers are the line.

  Addresses Colin's March 2026 review concerns:
  - TRUNCATE protection on all protected tables
  - Draws trigger state machine completeness
  - Append-only table enforcement
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers
  require Ash.Query

  alias WallopCore.Transparency.AnchorWorker

  # ── TRUNCATE protection ────────────────────────────────────────────

  describe "TRUNCATE protection" do
    test "draws cannot be TRUNCATEd" do
      assert_truncate_blocked("draws")
    end

    test "operators cannot be TRUNCATEd" do
      assert_truncate_blocked("operators")
    end

    test "entries cannot be TRUNCATEd" do
      assert_truncate_blocked("entries")
    end

    test "operator_signing_keys cannot be TRUNCATEd" do
      assert_truncate_blocked("operator_signing_keys")
    end

    test "operator_receipts cannot be TRUNCATEd" do
      assert_truncate_blocked("operator_receipts")
    end

    test "transparency_anchors cannot be TRUNCATEd" do
      assert_truncate_blocked("transparency_anchors")
    end

    test "infrastructure_signing_keys cannot be TRUNCATEd" do
      assert_truncate_blocked("infrastructure_signing_keys")
    end

    test "execution_receipts cannot be TRUNCATEd" do
      assert_truncate_blocked("execution_receipts")
    end
  end

  # ── Draws: terminal state protection ───────────────────────────────

  describe "draws: terminal states block all mutations" do
    setup do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)
      %{draw: executed}
    end

    test "cannot UPDATE string fields on completed draw", %{draw: draw} do
      for field <- ~w(seed name entry_hash) do
        assert_raise Postgrex.Error, ~r/Cannot modify a completed draw/, fn ->
          WallopCore.Repo.query!(
            "UPDATE draws SET #{field} = 'tampered' WHERE id = $1",
            [Ecto.UUID.dump!(draw.id)]
          )
        end
      end
    end

    test "cannot UPDATE integer fields on completed draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify a completed draw/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET winner_count = 999 WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "cannot UPDATE status on completed draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify a completed draw/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "cannot DELETE completed draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot delete a completed draw/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM draws WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  # ── Draws: committed field protection ──────────────────────────────

  describe "draws: committed fields frozen after lock" do
    setup do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      %{draw: draw}
    end

    test "cannot modify entry_hash on locked draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify committed entry fields/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET entry_hash = 'tampered' WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "cannot modify winner_count on locked draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify winner_count/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET winner_count = 999 WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "cannot modify declared entropy string fields on awaiting_entropy draw", %{draw: draw} do
      for field <- ~w(drand_chain weather_station) do
        assert_raise Postgrex.Error, ~r/Cannot modify declared entropy fields/, fn ->
          WallopCore.Repo.query!(
            "UPDATE draws SET #{field} = 'tampered' WHERE id = $1",
            [Ecto.UUID.dump!(draw.id)]
          )
        end
      end
    end

    test "cannot modify drand_round on awaiting_entropy draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify declared entropy fields/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET drand_round = 99999 WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "cannot modify weather_time on awaiting_entropy draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify declared entropy fields/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET weather_time = NOW() WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  # ── Draws: state transition validation ─────────────────────────────

  describe "draws: invalid state transitions blocked" do
    setup do
      api_key = create_api_key()
      draw = create_draw(api_key)
      %{draw: draw}
    end

    test "awaiting_entropy cannot jump to open", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Invalid state transition/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "awaiting_entropy cannot jump to expired", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Invalid state transition/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET status = 'expired' WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "pending_entropy cannot return to open" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      # Transition to pending_entropy
      draw =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      assert_raise Postgrex.Error, ~r/Invalid state transition/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "pending_entropy cannot return to awaiting_entropy" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      draw =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      assert_raise Postgrex.Error, ~r/Invalid state transition/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET status = 'awaiting_entropy' WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  describe "draws: failed state is terminal" do
    test "cannot UPDATE failed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      draw =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      draw =
        draw
        |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "test failure"})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      assert_raise Postgrex.Error, ~r/Cannot modify a failed draw/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET status = 'open' WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "cannot DELETE failed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      draw =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      _draw =
        draw
        |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "test failure"})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      assert_raise Postgrex.Error, ~r/Cannot delete a failed draw/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM draws WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  # ── Draws: caller-seed blocked when entropy declared ───────────────

  describe "draws: caller-seed blocked when entropy sources declared" do
    test "cannot set seed_source to caller when drand_round is set" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert_raise Postgrex.Error, ~r/Cannot use caller-provided seed/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET seed_source = 'caller' WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  # ── Entries: frozen after lock ─────────────────────────────────────

  describe "entries: frozen after draw leaves open" do
    setup do
      api_key = create_api_key()
      draw = create_draw(api_key)
      %{draw: draw}
    end

    test "cannot INSERT entry into locked draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify entries/, fn ->
        WallopCore.Repo.query!(
          "INSERT INTO entries (id, draw_id, entry_id, weight, inserted_at) VALUES ($1, $2, 'injected', 1, NOW())",
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "cannot DELETE entry from locked draw", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/Cannot modify entries/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM entries WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  # ── Append-only tables ─────────────────────────────────────────────

  describe "append-only: operator_signing_keys" do
    test "UPDATE blocked" do
      operator = create_operator()

      assert_raise Postgrex.Error, ~r/operator_signing_keys is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE operator_signing_keys SET key_id = 'x' WHERE operator_id = $1",
          [Ecto.UUID.dump!(operator.id)]
        )
      end
    end

    test "DELETE blocked" do
      operator = create_operator()

      assert_raise Postgrex.Error, ~r/operator_signing_keys is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM operator_signing_keys WHERE operator_id = $1",
          [Ecto.UUID.dump!(operator.id)]
        )
      end
    end
  end

  describe "append-only: operator_receipts" do
    setup do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      %{draw: draw}
    end

    test "UPDATE blocked", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/operator_receipts is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE operator_receipts SET sequence = 999 WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "DELETE blocked", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/operator_receipts is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM operator_receipts WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  describe "append-only: infrastructure_signing_keys" do
    test "UPDATE blocked" do
      key = create_infrastructure_key()

      assert_raise Postgrex.Error, ~r/infrastructure_signing_keys is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE infrastructure_signing_keys SET key_id = 'x' WHERE id = $1",
          [Ecto.UUID.dump!(key.id)]
        )
      end
    end

    test "DELETE blocked" do
      key = create_infrastructure_key()

      assert_raise Postgrex.Error, ~r/infrastructure_signing_keys is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM infrastructure_signing_keys WHERE id = $1",
          [Ecto.UUID.dump!(key.id)]
        )
      end
    end
  end

  describe "append-only: execution_receipts" do
    setup do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)
      %{draw: executed}
    end

    test "UPDATE blocked", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/execution_receipts is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE execution_receipts SET sequence = 999 WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end

    test "DELETE blocked", %{draw: draw} do
      assert_raise Postgrex.Error, ~r/execution_receipts is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM execution_receipts WHERE draw_id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  describe "append-only: transparency_anchors" do
    setup do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      _draw = create_draw(api_key) |> then(&execute_draw(&1, test_seed(), api_key))
      {:ok, anchor} = AnchorWorker.perform(%Oban.Job{})
      %{anchor: anchor}
    end

    test "UPDATE blocked", %{anchor: anchor} do
      assert_raise Postgrex.Error, ~r/transparency_anchors is append-only/, fn ->
        WallopCore.Repo.query!(
          "UPDATE transparency_anchors SET receipt_count = 999 WHERE id = $1",
          [Ecto.UUID.dump!(anchor.id)]
        )
      end
    end

    test "DELETE blocked", %{anchor: anchor} do
      assert_raise Postgrex.Error, ~r/transparency_anchors is append-only/, fn ->
        WallopCore.Repo.query!(
          "DELETE FROM transparency_anchors WHERE id = $1",
          [Ecto.UUID.dump!(anchor.id)]
        )
      end
    end
  end

  # ── Operator slug immutability ─────────────────────────────────────

  describe "operator slug immutability" do
    test "slug cannot be changed" do
      operator = create_operator("test-slug-immutable")

      assert_raise Postgrex.Error, ~r/operators.slug is immutable/, fn ->
        WallopCore.Repo.query!(
          "UPDATE operators SET slug = 'new-slug' WHERE id = $1",
          [Ecto.UUID.dump!(operator.id)]
        )
      end
    end

    test "name CAN be changed (only slug is immutable)" do
      operator = create_operator("test-name-mutable")

      {:ok, _} =
        WallopCore.Repo.query(
          "UPDATE operators SET name = 'New Name' WHERE id = $1",
          [Ecto.UUID.dump!(operator.id)]
        )
    end
  end

  # ── API key hash format constraint ─────────────────────────────────

  describe "api_keys key_hash format" do
    test "rejects garbage hash via direct SQL" do
      api_key = create_api_key()

      assert_raise Postgrex.Error, ~r/api_keys_key_hash_format/, fn ->
        WallopCore.Repo.query!(
          "UPDATE api_keys SET key_hash = 'not-a-bcrypt-hash' WHERE id = $1",
          [Ecto.UUID.dump!(api_key.id)]
        )
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp assert_truncate_blocked(table) do
    assert_raise Postgrex.Error, ~r/cannot be TRUNCATEd|cannot truncate/, fn ->
      WallopCore.Repo.query!("TRUNCATE #{table} CASCADE")
    end
  end
end
