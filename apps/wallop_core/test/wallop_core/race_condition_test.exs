defmodule WallopCore.RaceConditionTest do
  @moduledoc """
  Concurrency tests verifying that state transitions are safe under
  concurrent access. Uses real Postgres (async: false) to test actual
  row-level locking and WHERE clause atomicity.
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Resources.Draw

  describe "concurrent lock attempts" do
    test "exactly one of two concurrent locks succeeds" do
      api_key = create_api_key()

      # Create a draw in :open state
      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}, %{"id" => "b", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      # Launch two concurrent lock attempts
      task1 =
        Task.async(fn ->
          draw
          |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
          |> Ash.update()
        end)

      task2 =
        Task.async(fn ->
          draw
          |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
          |> Ash.update()
        end)

      results = [Task.await(task1), Task.await(task2)]
      successes = Enum.count(results, &match?({:ok, _}, &1))
      errors = Enum.count(results, &match?({:error, _}, &1))

      # Exactly one should succeed
      assert successes == 1, "expected exactly 1 success, got #{successes}"
      assert errors == 1, "expected exactly 1 error, got #{errors}"

      # The draw should be in awaiting_entropy
      {:ok, refreshed} = Ash.get(Draw, draw.id, authorize?: false)
      assert refreshed.status == :awaiting_entropy
    end
  end

  describe "concurrent entry addition and lock" do
    test "entry added after lock is rejected by DB trigger" do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"id" => "a", "weight" => 1}]},
          actor: api_key
        )
        |> Ash.update!()

      # Lock the draw
      locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
        |> Ash.update!()

      assert locked.status == :awaiting_entropy

      # Attempting to add an entry via raw SQL should be rejected by trigger
      assert_raise Postgrex.Error, ~r/Cannot modify entries/, fn ->
        WallopCore.Repo.query!(
          "INSERT INTO entries (id, draw_id, entry_id, weight, inserted_at) VALUES ($1, $2, 'injected', 1, NOW())",
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  describe "completed draw cannot be re-executed" do
    test "second execution attempt fails" do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      assert executed.status == :completed

      # Attempting to execute again via raw SQL is blocked by trigger
      assert_raise Postgrex.Error, ~r/Cannot modify a completed draw/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET status = 'pending_entropy' WHERE id = $1",
          [Ecto.UUID.dump!(executed.id)]
        )
      end
    end
  end

  describe "mark_failed vs execute race" do
    test "only one of mark_failed or execute succeeds on the same draw" do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)

      # Transition to pending_entropy
      draw =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      assert draw.status == :pending_entropy

      # Launch concurrent execute and mark_failed
      task_exec =
        Task.async(fn ->
          draw
          |> Ash.Changeset.for_update(:execute_with_entropy, %{
            drand_randomness: test_drand_randomness(),
            drand_signature: "test-sig",
            drand_response: "{}",
            weather_value: "1013",
            weather_raw: "{}",
            weather_observation_time: DateTime.add(DateTime.utc_now(), -60, :second)
          })
          |> Ash.update(domain: WallopCore.Domain, authorize?: false)
        end)

      task_fail =
        Task.async(fn ->
          draw
          |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "race test"})
          |> Ash.update(domain: WallopCore.Domain, authorize?: false)
        end)

      results = [Task.await(task_exec, 10_000), Task.await(task_fail, 10_000)]
      successes = Enum.count(results, &match?({:ok, _}, &1))

      # Exactly one should succeed
      assert successes == 1, "expected exactly 1 success, got #{successes}: #{inspect(results)}"

      # The draw should be in a terminal state
      {:ok, refreshed} = Ash.get(Draw, draw.id, authorize?: false)
      assert refreshed.status in [:completed, :failed]
    end
  end
end
