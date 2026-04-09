defmodule WallopCore.RaceConditionTest do
  @moduledoc """
  Concurrency tests verifying that state transitions are safe under
  concurrent access.

  Tests 1-2 use raw Postgrex connections to test real concurrent
  UPDATE ... WHERE atomicity, bypassing the Ecto sandbox.

  Tests 3-4 use the normal Ecto sandbox for trigger verification.
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Resources.Draw

  describe "concurrent lock attempts (real concurrency)" do
    test "exactly one of two concurrent UPDATE ... WHERE status = open succeeds" do
      {:ok, conn1} = raw_connection()
      {:ok, conn2} = raw_connection()
      {:ok, setup_conn} = raw_connection()

      draw_id = Ecto.UUID.generate()
      api_key_id = Ecto.UUID.generate()
      operator_id = Ecto.UUID.generate()
      draw_id_bin = Ecto.UUID.dump!(draw_id)
      api_key_id_bin = Ecto.UUID.dump!(api_key_id)
      operator_id_bin = Ecto.UUID.dump!(operator_id)

      # Create minimal operator, api_key, and draw via raw SQL
      Postgrex.query!(
        setup_conn,
        "INSERT INTO operators (id, slug, name, inserted_at, updated_at) VALUES ($1, $2, 'Race Op', NOW(), NOW())",
        [operator_id_bin, "race-#{String.slice(operator_id, 0, 8)}"]
      )

      Postgrex.query!(
        setup_conn,
        "INSERT INTO api_keys (id, name, key_hash, key_prefix, active, monthly_draw_count, operator_id, inserted_at, updated_at) VALUES ($1, $3, '$2b$04$AAAAAAAAAAAAAAAAAAAAAO6jGWxQhMFTXHCJFRlbNqjh22V6IlCzK', $3, true, 0, $2, NOW(), NOW())",
        [api_key_id_bin, operator_id_bin, "wlp_#{String.slice(api_key_id, 0, 8)}"]
      )

      Postgrex.query!(
        setup_conn,
        "INSERT INTO draws (id, status, winner_count, entry_count, api_key_id, operator_id, operator_sequence, inserted_at, updated_at) VALUES ($1, 'open', 1, 2, $2, $3, 1, NOW(), NOW())",
        [draw_id_bin, api_key_id_bin, operator_id_bin]
      )

      task1 =
        Task.async(fn ->
          Postgrex.query!(
            conn1,
            "UPDATE draws SET status = 'awaiting_entropy' WHERE id = $1 AND status = 'open' RETURNING id",
            [draw_id_bin]
          )
        end)

      task2 =
        Task.async(fn ->
          Postgrex.query!(
            conn2,
            "UPDATE draws SET status = 'awaiting_entropy' WHERE id = $1 AND status = 'open' RETURNING id",
            [draw_id_bin]
          )
        end)

      r1 = Task.await(task1)
      r2 = Task.await(task2)

      affected = r1.num_rows + r2.num_rows
      assert affected == 1, "expected 1 total affected row, got #{affected}"

      # Cleanup
      Postgrex.query!(setup_conn, "DELETE FROM draws WHERE id = $1", [draw_id_bin])
      Postgrex.query!(setup_conn, "DELETE FROM api_keys WHERE id = $1", [api_key_id_bin])
      Postgrex.query!(setup_conn, "SET session_replication_role = 'replica'", [])
      Postgrex.query!(setup_conn, "DELETE FROM operators WHERE id = $1", [operator_id_bin])
      Postgrex.query!(setup_conn, "SET session_replication_role = 'origin'", [])

      for c <- [conn1, conn2, setup_conn], do: GenServer.stop(c)
    end
  end

  describe "mark_failed vs execute race (real concurrency)" do
    test "exactly one of two competing state transitions succeeds" do
      {:ok, conn1} = raw_connection()
      {:ok, conn2} = raw_connection()
      {:ok, setup_conn} = raw_connection()

      draw_id = Ecto.UUID.generate()
      api_key_id = Ecto.UUID.generate()
      operator_id = Ecto.UUID.generate()
      draw_id_bin = Ecto.UUID.dump!(draw_id)
      api_key_id_bin = Ecto.UUID.dump!(api_key_id)
      operator_id_bin = Ecto.UUID.dump!(operator_id)

      Postgrex.query!(
        setup_conn,
        "INSERT INTO operators (id, slug, name, inserted_at, updated_at) VALUES ($1, $2, 'Race Op 2', NOW(), NOW())",
        [operator_id_bin, "race-#{String.slice(operator_id, 0, 8)}"]
      )

      Postgrex.query!(
        setup_conn,
        "INSERT INTO api_keys (id, name, key_hash, key_prefix, active, monthly_draw_count, operator_id, inserted_at, updated_at) VALUES ($1, $3, '$2b$04$AAAAAAAAAAAAAAAAAAAAAO6jGWxQhMFTXHCJFRlbNqjh22V6IlCzK', $3, true, 0, $2, NOW(), NOW())",
        [api_key_id_bin, operator_id_bin, "wlp_#{String.slice(api_key_id, 0, 8)}"]
      )

      Postgrex.query!(
        setup_conn,
        "INSERT INTO draws (id, status, winner_count, entry_count, api_key_id, operator_id, operator_sequence, inserted_at, updated_at) VALUES ($1, 'pending_entropy', 1, 1, $2, $3, 1, NOW(), NOW())",
        [draw_id_bin, api_key_id_bin, operator_id_bin]
      )

      task_complete =
        Task.async(fn ->
          Postgrex.query!(
            conn1,
            "UPDATE draws SET status = 'completed' WHERE id = $1 AND status = 'pending_entropy' RETURNING id",
            [draw_id_bin]
          )
        end)

      task_fail =
        Task.async(fn ->
          Postgrex.query!(
            conn2,
            "UPDATE draws SET status = 'failed' WHERE id = $1 AND status = 'pending_entropy' RETURNING id",
            [draw_id_bin]
          )
        end)

      r1 = Task.await(task_complete)
      r2 = Task.await(task_fail)

      affected = r1.num_rows + r2.num_rows
      assert affected == 1, "expected 1 total affected row, got #{affected}"

      %{rows: [[status]]} =
        Postgrex.query!(setup_conn, "SELECT status FROM draws WHERE id = $1", [draw_id_bin])

      assert status in ["completed", "failed"]

      # Cleanup — bypass trigger for terminal state delete
      Postgrex.query!(setup_conn, "SET session_replication_role = 'replica'", [])
      Postgrex.query!(setup_conn, "DELETE FROM draws WHERE id = $1", [draw_id_bin])
      Postgrex.query!(setup_conn, "DELETE FROM api_keys WHERE id = $1", [api_key_id_bin])
      Postgrex.query!(setup_conn, "DELETE FROM operators WHERE id = $1", [operator_id_bin])
      Postgrex.query!(setup_conn, "SET session_replication_role = 'origin'", [])

      for c <- [conn1, conn2, setup_conn], do: GenServer.stop(c)
    end
  end

  describe "entry insertion after lock (DB trigger)" do
    test "rejected by entries immutability trigger" do
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

      locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
        |> Ash.update!()

      assert locked.status == :awaiting_entropy

      assert_raise Postgrex.Error, ~r/Cannot modify entries/, fn ->
        WallopCore.Repo.query!(
          "INSERT INTO entries (id, draw_id, entry_id, weight, inserted_at) VALUES ($1, $2, 'injected', 1, NOW())",
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(draw.id)]
        )
      end
    end
  end

  describe "completed draw re-execution (immutability trigger)" do
    test "blocked by DB trigger" do
      _infra_key = create_infrastructure_key()
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      draw = create_draw(api_key)
      executed = execute_draw(draw, test_seed(), api_key)

      assert executed.status == :completed

      assert_raise Postgrex.Error, ~r/Cannot modify a completed draw/, fn ->
        WallopCore.Repo.query!(
          "UPDATE draws SET status = 'pending_entropy' WHERE id = $1",
          [Ecto.UUID.dump!(executed.id)]
        )
      end
    end
  end

  defp raw_connection do
    config = WallopCore.Repo.config()

    Postgrex.start_link(
      hostname: config[:hostname] || "localhost",
      port: config[:port] || 5432,
      username: config[:username] || "postgres",
      password: config[:password] || "postgres",
      database: config[:database]
    )
  end
end
