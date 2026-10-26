defmodule WallopCore.Attacks.ForgedCompletionTest do
  @moduledoc """
  Raw SQL must not complete an observation-weather draw with winners of its
  choosing and no execution receipt.

  The draws guard checks a v6 completion's weather fields and its
  `executed_at`, but not `seed` or `results` (no FairPick in SQL). Only the
  execution receipt guard ties those to a signature. So a v6 draw that
  becomes `completed` must have its execution receipt by COMMIT: a
  DEFERRABLE INITIALLY DEFERRED constraint trigger on draws
  (`draws_v6_completed_commit`). Execution inserts the receipt in the
  completion's own transaction, so it is unaffected.

  The first two tests commit for real (outside the sandbox) and clean up
  after themselves. The others stay in the sandbox and fire the deferred
  check early with `SET CONSTRAINTS ... IMMEDIATE`.
  """
  use WallopCore.InvariantCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.Schedule

  @w Schedule.fetch_window_seconds()
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @signature "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"
  @refusal "a v6 draw must commit its execution receipt with its completion"

  @complete_sql """
  UPDATE draws SET status = 'completed', executed_at = $2, seed = $3,
    seed_source = 'entropy', results = ARRAY[$4::jsonb],
    drand_randomness = $5, drand_signature = $6,
    weather_value = NULL, weather_observation_time = NULL,
    weather_fallback_reason = $7, freq_fallback_reason = 'no_frequency_by_deadline'
  WHERE id = $1
  """

  @tag :slow
  test "a v6 draw can't be committed as completed without its execution receipt" do
    draw = unboxed_ready_draw()
    [chosen | _] = unboxed(fn -> WallopCore.Entries.load_for_draw(draw.id) end)

    outcome =
      commit(fn ->
        Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])
        Repo.query!(@complete_sql, complete_params(draw, chosen.uuid))
      end)

    assert outcome == {:refused, @refusal}
    assert unboxed(fn -> reload(draw).status end) == :awaiting_entropy
  end

  @tag :slow
  test "a completion committed with its receipt in the same transaction is kept" do
    # Positive control for the commit-time check alone: the receipt row is
    # a placeholder, inserted with triggers off, so only the deferred check
    # is exercised.
    draw = unboxed_ready_draw()
    [chosen | _] = unboxed(fn -> WallopCore.Entries.load_for_draw(draw.id) end)

    outcome =
      commit(fn ->
        Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])
        Repo.query!(@complete_sql, complete_params(draw, chosen.uuid))
        Repo.query!("SET LOCAL session_replication_role = replica")
        insert_placeholder_receipt!(draw)
        Repo.query!("SET LOCAL session_replication_role = origin")
      end)

    assert outcome == :committed
    assert unboxed(fn -> reload(draw).status end) == :completed
  end

  test "real execution satisfies the commit-time check" do
    ensure_infrastructure_key()
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(-(@w + 180)) |> DateTime.truncate(:second)
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)
    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])

    assert check_now(fn ->
             reload(draw)
             |> Ash.Changeset.for_update(:execute_v6, %{
               drand_randomness: @randomness,
               drand_signature: @signature,
               drand_response: "{}"
             })
             # Run inside check_now's savepoint on purpose.
             |> Ash.Changeset.set_context(%{warn_on_transaction_hooks?: false})
             |> Ash.update!(authorize?: false)
           end) == nil
  end

  test "the commit-time check refuses a sandboxed completion with no receipt" do
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(-(@w + 180)) |> DateTime.truncate(:second)
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round)
    [chosen | _] = WallopCore.Entries.load_for_draw(draw.id)

    assert check_now(fn ->
             Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
               dump(draw.id)
             ])

             Repo.query!(@complete_sql, complete_params(draw, chosen.uuid))
           end) == @refusal
  end

  test "a retired forecast draw completed with no execution receipt is untouched by the check" do
    forecast = put_retired_forecast_draw!(create_api_key(), :awaiting_entropy)

    assert check_now(fn ->
             with_triggers_off(fn ->
               Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
                 dump(forecast.id)
               ])
             end)

             Repo.query!(
               "UPDATE draws SET status = 'completed', executed_at = now(), seed = $2 WHERE id = $1",
               [dump(forecast.id), String.duplicate("ab", 32)]
             )
           end) == nil
  end

  defp complete_params(draw, chosen_id) do
    [
      dump(draw.id),
      NaiveDateTime.utc_now(),
      String.duplicate("ab", 32),
      %{"position" => 1, "entry_id" => chosen_id},
      @randomness,
      @signature,
      LandObs.fallback_reason()
    ]
  end

  # Runs `fun` in a savepoint, then fires the deferred completion check at
  # once. nil when accepted, or the refusal's message. Always rolled back.
  defp check_now(fun) do
    try_sql_fun(fn ->
      fun.()
      Repo.query!("SET CONSTRAINTS draws_v6_completed_commit IMMEDIATE")
    end)
  end

  defp try_sql_fun(fun) do
    {:error, :accepted} =
      Repo.transaction(fn ->
        fun.()
        Repo.rollback(:accepted)
      end)

    nil
  rescue
    e in Postgrex.Error -> e.postgres.message
  end

  defp insert_placeholder_receipt!(draw) do
    Repo.query!(
      """
      INSERT INTO execution_receipts (id, draw_id, operator_id, sequence, lock_receipt_hash,
        payload_jcs, signature, signing_key_id)
      VALUES ($1, $2, $3, $4, 'x', '{}', $5, 'k')
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(draw.id),
        dump(draw.operator_id),
        draw.operator_sequence,
        :binary.copy(<<0>>, 64)
      ]
    )
  end

  defp reload(draw), do: Ash.get!(Draw, draw.id, authorize?: false)

  # A v6 draw past F + 1 minute and past pub(R), committed outside the
  # sandbox for a fresh operator, removed at the end of the test.
  defp unboxed_ready_draw do
    {operator, draw} =
      unboxed(fn ->
        {operator, key} = create_v6_operator()
        wt = DateTime.utc_now() |> DateTime.add(-(@w + 180)) |> DateTime.truncate(:second)
        round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))
        {operator, put_v6_awaiting!(open_draw_with_entries(key), wt, round)}
      end)

    on_exit(fn -> unboxed(fn -> delete_operator!(operator.id) end) end)
    draw
  end

  defp commit(fun) do
    unboxed(fn ->
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '10s'")
          fun.()
        end)
    end)

    :committed
  rescue
    e in Postgrex.Error -> {:refused, e.postgres.message}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp delete_operator!(operator_id) do
    id = dump(operator_id)
    draws = "SELECT id FROM draws WHERE operator_id = $1"

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")

      for sql <- [
            "DELETE FROM oban_jobs WHERE args->>'draw_id' IN (SELECT id::text FROM draws WHERE operator_id = $1)",
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
