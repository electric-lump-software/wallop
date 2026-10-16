defmodule WallopCore.Weather.V6ExecutionGuardsTest do
  @moduledoc """
  The database guards on how an observation-weather (v6) draw ends: the
  execution receipt guard, the delete guard, and the fallback grace in the
  completion guard. Every one is a no-op for a draw with no lock schema
  (every forecast and historic draw), and each test that says so proves it.
  The refusal of `failed` after pub(R) is pinned by INV-9.
  """
  # Not async: the observation store has one row per hour across the database.
  use WallopCore.DataCase, async: false

  import WallopCore.InvariantCase, except: [__using__: 1]
  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.{Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @value "141;1025;85;2432"
  @not_valid "v6 execution receipt signing key was not valid at executed_at"
  @grace "a v6 execution receipt may fall back only after the fetch deadline with nothing stored"
  @no_delete "a v6 draw can't be deleted once it has left open"
  @fallback_late "v6 draw may fall back only after the fetch deadline with nothing stored"

  defp build(input), do: Protocol.build_v6_execution_payload(input)

  defp round_at(offset), do: Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), offset))

  # A stored weather_time whose fetch deadline F was `ago` seconds ago.
  defp wt_with_deadline_ago(ago),
    do: DateTime.utc_now() |> DateTime.add(-(@w + ago)) |> DateTime.truncate(:second)

  defp forecast_cols(draw),
    do: %{
      draw_id: draw.id,
      operator_id: draw.operator_id,
      sequence: 1_000_000 + System.unique_integer([:positive]),
      lock_receipt_hash: "x",
      signing_key_id: "k"
    }

  defp complete_by_fallback(draw) do
    try_sql(
      "UPDATE draws SET status = 'completed', executed_at = $2, weather_fallback_reason = $3 WHERE id = $1",
      [dump(draw.id), NaiveDateTime.utc_now(), LandObs.fallback_reason()]
    )
  end

  defp pending_v6(wt) do
    {_op, key} = create_v6_operator()
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(-10))
    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])
    draw
  end

  describe "the execution receipt guard" do
    test "is in place on execution_receipts" do
      assert %{rows: [["O"]]} =
               Repo.query!(
                 "SELECT tgenabled::text FROM pg_trigger WHERE tgname = 'execution_receipts_v6_guard'"
               )
    end

    test "leaves a forecast draw's execution receipts alone, refusing only schema 5" do
      draw = create_draw(create_api_key())

      for payload <- ["not json", ~s({"schema_version":"4"}), ~s([5]), ~s("5")] do
        assert insert_exec_receipt(payload, forecast_cols(draw)) == nil, payload
      end

      assert insert_exec_receipt(~s({"schema_version":"5"}), forecast_cols(draw)) ==
               "a schema 5 execution receipt needs a draw locked under schema 6"
    end

    test "accepts the signer's receipt, observed or fallback" do
      for {kind, hours} <- [observed: 1, fallback: 2] do
        x = completed_v6_receipt_input(kind, hours_ago: hours)
        assert insert_exec_receipt(build(x.input), x.cols) == nil, "#{kind}"
      end
    end

    test "needs the draw completed first" do
      x = completed_v6_receipt_input(:fallback)

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [
          dump(x.draw.id)
        ])
      end)

      assert insert_exec_receipt(build(x.input), x.cols) ==
               "a v6 execution receipt needs its draw completed first"
    end

    test "needs the draw's lock receipt" do
      x = completed_v6_receipt_input(:fallback)

      with_triggers_off(fn ->
        Repo.query!("DELETE FROM operator_receipts WHERE draw_id = $1", [dump(x.draw.id)])
      end)

      assert insert_exec_receipt(build(x.input), x.cols) ==
               "a v6 execution receipt needs its draw's lock receipt"
    end

    test "needs an infrastructure key that was in the keyring, and eligible, at executed_at" do
      x = completed_v6_receipt_input(:observed)
      executed_at = DateTime.to_naive(x.input.executed_at)

      late_insert = create_infrastructure_key()
      late_valid = create_infrastructure_key()

      with_triggers_off(fn ->
        Repo.query!(
          "UPDATE infrastructure_signing_keys SET inserted_at = $2::timestamp + interval '1 second' WHERE key_id = $1",
          [late_insert.key_id, executed_at]
        )

        Repo.query!(
          "UPDATE infrastructure_signing_keys SET valid_from = $2::timestamp + interval '1 microsecond' WHERE key_id = $1",
          [late_valid.key_id, executed_at]
        )
      end)

      for key_id <- [late_insert.key_id, late_valid.key_id, "deadbeef"] do
        input = %{x.input | signing_key_id: key_id}
        cols = %{x.cols | signing_key_id: key_id}
        assert insert_exec_receipt(build(input), cols) == @not_valid, key_id
      end
    end

    test "a fallback receipt waits a minute past the fetch deadline" do
      # Completed with triggers off: the completion guard would refuse it.
      early =
        completed_v6_receipt_input(:fallback,
          weather_time: wt_with_deadline_ago(30),
          triggers_off: true
        )

      assert insert_exec_receipt(build(early.input), early.cols) == @grace

      later = completed_v6_receipt_input(:fallback, weather_time: wt_with_deadline_ago(90))
      assert insert_exec_receipt(build(later.input), later.cols) == nil
    end

    test "a reading for a fallback hour is refused" do
      x = completed_v6_receipt_input(:fallback)

      input = %{
        x.input
        | weather_value: @value,
          weather_observation_time: x.wt,
          weather_fallback_reason: nil
      }

      assert insert_exec_receipt(build(input), x.cols) ==
               "v6 execution receipt field weather_value does not match the stored observation"
    end

    test "another station than the stored reading's is refused" do
      x = completed_v6_receipt_input(:observed, station: Stations.backup().id)
      input = %{x.input | weather_station: Stations.primary().id}

      assert insert_exec_receipt(build(input), x.cols) ==
               "v6 execution receipt field weather_station does not match the stored observation"
    end
  end

  describe "the delete guard" do
    test "a v6 draw that has left open can't be deleted, in any status" do
      {_op, key} = create_v6_operator()

      awaiting =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(-600), round_at(3600))

      pending =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(-600), round_at(3600))

      Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(pending.id)])

      # Failing is allowed before pub(R).
      failed =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(-600), round_at(3600))

      Repo.query!("UPDATE draws SET status = 'failed' WHERE id = $1", [dump(failed.id)])

      completed = completed_v6_receipt_input(:fallback, api_key: key).draw

      for draw <- [awaiting, pending, failed, completed] do
        assert try_sql("DELETE FROM draws WHERE id = $1", [dump(draw.id)]) == @no_delete
      end

      # Its receipts are not what stops it: with them gone it is still refused.
      with_triggers_off(fn ->
        Repo.query!("DELETE FROM operator_receipts WHERE draw_id = $1", [dump(awaiting.id)])
      end)

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(awaiting.id)]) == @no_delete
    end

    test "an open draw of an observation operator can still be deleted" do
      {_op, key} = create_v6_operator()
      draw = open_draw_with_entries(key)
      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(draw.id)]) == nil
    end

    test "forecast draws are deleted, or refused, exactly as before" do
      api_key = create_api_key()

      open =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(open.id)]) == nil

      # A locked forecast draw: its lock receipt's foreign key refuses, and
      # with the receipt gone the draw is deletable, as before.
      locked = create_draw(api_key)
      assert locked.status == :awaiting_entropy

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(locked.id)]) =~
               ~s(violates RESTRICT setting of foreign key constraint "operator_receipts_draw_id_fkey")

      with_triggers_off(fn ->
        Repo.query!("DELETE FROM operator_receipts WHERE draw_id = $1", [dump(locked.id)])
      end)

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(locked.id)]) == nil

      done = create_draw(api_key)

      with_triggers_off(fn ->
        Repo.query!("UPDATE draws SET status = 'completed' WHERE id = $1", [dump(done.id)])
      end)

      assert try_sql("DELETE FROM draws WHERE id = $1", [dump(done.id)]) ==
               "Cannot delete a completed draw"
    end
  end

  describe "the fallback grace in the completion guard" do
    test "after F but within a minute of it, the fallback is refused" do
      assert complete_by_fallback(pending_v6(wt_with_deadline_ago(30))) == @fallback_late
    end

    test "more than a minute after F, the fallback completes" do
      assert complete_by_fallback(pending_v6(wt_with_deadline_ago(90))) == nil
    end

    test "a stored reading completes within that minute: the grace is for the fallback only" do
      wt = wt_with_deadline_ago(30)
      draw = pending_v6(wt)
      put_observation!(Stations.primary().id, wt, @value)

      assert try_sql(
               "UPDATE draws SET status = 'completed', executed_at = $2, weather_value = $3, weather_observation_time = $4 WHERE id = $1",
               [dump(draw.id), NaiveDateTime.utc_now(), @value, DateTime.to_naive(wt)]
             ) == nil
    end
  end

  describe "under a non-UTC session" do
    # +13:45: a guard reading local time instead of UTC would let the early
    # fallback through and refuse the early fail.
    setup do
      Repo.query!("SET LOCAL TIME ZONE 'Pacific/Chatham'")
      :ok
    end

    test "the fallback grace holds on both guards" do
      assert complete_by_fallback(pending_v6(wt_with_deadline_ago(30))) == @fallback_late
      assert complete_by_fallback(pending_v6(wt_with_deadline_ago(90))) == nil

      early =
        completed_v6_receipt_input(:fallback,
          weather_time: wt_with_deadline_ago(30),
          triggers_off: true
        )

      assert insert_exec_receipt(build(early.input), early.cols) == @grace

      later = completed_v6_receipt_input(:fallback, weather_time: wt_with_deadline_ago(90))
      assert insert_exec_receipt(build(later.input), later.cols) == nil
    end

    test "failing is refused from pub(R), allowed before it" do
      {_op, key} = create_v6_operator()
      fail = "UPDATE draws SET status = 'failed' WHERE id = $1"

      published =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(60), round_at(-10))

      assert try_sql(fail, [dump(published.id)]) ==
               "a v6 draw can't fail once its drand round is published"

      ahead =
        put_v6_awaiting!(open_draw_with_entries(key), wt_with_deadline_ago(-600), round_at(600))

      assert try_sql(fail, [dump(ahead.id)]) == nil
    end
  end
end
