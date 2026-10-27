defmodule WallopCore.UnboxedHelpers do
  @moduledoc """
  Helpers for tests that run real transactions outside the Ecto sandbox
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`). Every fixture such a test
  commits belongs to one fresh operator, removed by `delete_operator!/1`
  in `on_exit`.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias WallopCore.Repo

  @doc "Runs `fun` on a connection outside the sandbox, which really commits."
  def unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  @doc """
  Runs `statement` in a real transaction in a new process, linked to the
  caller: if the test fails or exits first, the process dies with it, and
  its connection's transaction (and any lock it holds) is rolled back
  rather than left open. Sends
  `{:done_statement, pid}` once it returns, then waits for `:commit` or
  `:rollback`, and sends `{:result, pid, :committed | :rolled_back |
  {:refused, message}}`.
  """
  def in_transaction(statement) do
    parent = self()

    spawn_link(fn ->
      me = self()

      result =
        try do
          unboxed(fn ->
            Repo.transaction(
              fn ->
                Repo.query!("SET LOCAL lock_timeout = '10s'")
                statement.()
                send(parent, {:done_statement, me})

                receive do
                  :commit -> :ok
                  :rollback -> Repo.rollback(:rolled_back)
                after
                  30_000 -> Repo.rollback(:no_commit)
                end
              end,
              timeout: 60_000
            )
          end)
        rescue
          e in Postgrex.Error -> {:refused, e.postgres.message}
        end

      case result do
        {:ok, :ok} -> send(parent, {:result, me, :committed})
        {:error, :rolled_back} -> send(parent, {:result, me, :rolled_back})
        other -> send(parent, {:result, me, other})
      end
    end)
  end

  @doc "Waits until the database clock (clock_timestamp(), UTC) is past `t`."
  def wait_until_db_clock_after(%DateTime{} = t) do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp() AT TIME ZONE 'UTC'")

    if DateTime.compare(DateTime.from_naive!(now, "Etc/UTC"), t) == :gt do
      :ok
    else
      Process.sleep(200)
      wait_until_db_clock_after(t)
    end
  end

  @doc """
  Deletes an operator committed outside the sandbox and everything it owns:
  its draws' stored readings and windows, Oban jobs, receipts, entries,
  draws, keys and versions. Triggers are off for the deletes.
  """
  def delete_operator!(operator_id) do
    id = Ecto.UUID.dump!(operator_id)
    draws = "SELECT id FROM draws WHERE operator_id = $1"

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")

      for {table, sql} <- [
            {"weather_observations",
             "DELETE FROM weather_observations WHERE observation_time IN " <>
               "(SELECT weather_time FROM draws WHERE operator_id = $1)"},
            {"frequency_windows",
             "DELETE FROM frequency_windows WHERE freq_start IN " <>
               "(SELECT freq_start FROM draws WHERE operator_id = $1)"}
          ],
          %{rows: [[found]]} <- [Repo.query!("SELECT to_regclass($1)::text", [table])],
          found do
        Repo.query!(sql, [id])
      end

      for sql <- [
            "DELETE FROM oban_jobs WHERE args->>'draw_id' IN (SELECT id::text FROM draws WHERE operator_id = $1)",
            "DELETE FROM oban_jobs j WHERE j.args ? 'freq_start' AND EXISTS " <>
              "(SELECT 1 FROM draws d WHERE d.operator_id = $1 " <>
              "AND (j.args->>'freq_start')::timestamptz = d.freq_start AT TIME ZONE 'UTC')",
            "DELETE FROM execution_receipts WHERE operator_id = $1",
            "DELETE FROM operator_receipts WHERE operator_id = $1",
            "DELETE FROM add_entries_idempotency WHERE draw_id IN (#{draws})",
            "DELETE FROM entries WHERE draw_id IN (#{draws})",
            "DELETE FROM draws WHERE operator_id = $1",
            "DELETE FROM api_keys WHERE operator_id = $1",
            "DELETE FROM operator_signing_keys WHERE operator_id = $1",
            "DELETE FROM operators_versions WHERE version_source_id = $1",
            "DELETE FROM operators WHERE id = $1"
          ] do
        Repo.query!(sql, [id])
      end
    end)
  end
end
