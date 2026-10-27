defmodule WallopCore.Attacks.ParkedJobTest do
  @moduledoc """
  Selective, silent sticking after pub(R) with one row write in `oban_jobs`
  (partial DB compromise: raw SQL, no superuser).

  Once round R publishes, anyone with the entries and the stored window can
  compute the winners. An attacker who doesn't like them moves the draw's
  `ObservationDrawWorker` job out of reach: `scheduled_at = 2099`, another
  queue, no attempts left, or `suspended`. The draw can't be failed after F
  (the database refuses), but it never completes either. The re-drive
  counted any job in a live state as "being handled", so it never
  re-inserted one, and nothing reported the draw.

  Fixed in `StuckDrawRedriver`:

    * a schema 6 draw's live job counts only when it can still run the draw
      soon (its own queue, attempts left, due within the worker's longest
      delay, or executing); a parked job is cancelled, with the reason, and
      a new job inserted;
    * every run reports each schema 6 draw past pub(R) + 15 minutes that is
      neither completed nor refused by the executor as
      `[:wallop_core, :v6, :overdue]`, whatever its jobs say. A cancelled
      row inserted by hand carries no refusal, so its draw is still
      reported.

  Both tags. Forecast draws are untouched (see the redriver's own tests).
  """
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{ObservationDrawWorker, StuckDrawRedriver}
  alias WallopCore.Frequency.Schedule
  alias WallopCore.Weather.Schedule, as: WeatherSchedule

  @moduletag :capture_log

  @reinserted [:wallop_core, :redrive, :reinserted]
  @overdue [:wallop_core, :v6, :overdue]

  setup do
    %{ref: :telemetry_test.attach_event_handlers(self(), [@reinserted, @overdue])}
  end

  defp freq_draw(ago \\ 20 * 60) do
    {_op, key} = create_freq_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -ago))

    draw =
      put_freq_awaiting!(open_draw_with_entries(key), Schedule.freq_start_for_round(round), round)

    clear_jobs(draw)
  end

  defp landobs_draw(ago \\ 20 * 60) do
    {_op, key} = create_v6_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -ago))
    wt = WeatherSchedule.weather_time_for_round(round)
    clear_jobs(put_v6_awaiting!(open_draw_with_entries(key), wt, round))
  end

  defp clear_jobs(draw) do
    Repo.query!("DELETE FROM oban_jobs WHERE args->>'draw_id' = $1", [draw.id])
    draw
  end

  defp job!(draw, set) do
    {:ok, job} = Oban.insert(ObservationDrawWorker.new(%{draw_id: draw.id}))
    if set, do: Repo.query!("UPDATE oban_jobs SET #{set} WHERE id = $1", [job.id])
    job
  end

  defp jobs(draw) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, state, queue, meta FROM oban_jobs WHERE args->>'draw_id' = $1 ORDER BY id",
        [draw.id]
      )

    rows
  end

  defp assert_replaced(draw, parked, ref) do
    id = draw.id
    assert id in StuckDrawRedriver.redrive()
    assert_received {@reinserted, ^ref, %{count: 1}, %{draw_id: ^id, replaced: 1}}

    assert [[old_id, "cancelled", _, %{"redrive_replaced" => true}], [_, "available", queue, _]] =
             jobs(draw)

    assert old_id == parked.id
    assert queue == "v6_execution"
  end

  describe "a parked job is replaced" do
    for {name, set} <- [
          {"scheduled for 2099", "state = 'scheduled', scheduled_at = '2099-01-01 00:00:00'"},
          {"retryable until 2099", "state = 'retryable', scheduled_at = '2099-01-01 00:00:00'"},
          {"on a queue nothing runs", "queue = 'nowhere'"},
          {"out of attempts", "attempt = max_attempts"},
          {"suspended", "state = 'suspended'"}
        ] do
      @set set
      test "grid frequency: #{name}", %{ref: ref} do
        draw = freq_draw()
        assert_replaced(draw, job!(draw, @set), ref)
      end

      test "Land Obs: #{name}", %{ref: ref} do
        draw = landobs_draw()
        assert_replaced(draw, job!(draw, @set), ref)
      end
    end

    test "the replacement is not re-driven again, and the cancelled row doesn't park the draw",
         %{ref: ref} do
      draw = freq_draw()
      job!(draw, "state = 'scheduled', scheduled_at = '2099-01-01 00:00:00'")
      assert draw.id in StuckDrawRedriver.redrive()

      refute draw.id in StuckDrawRedriver.redrive()

      Repo.query!(
        "UPDATE oban_jobs SET state = 'discarded', discarded_at = now() " <>
          "WHERE args->>'draw_id' = $1 AND state = 'available'",
        [draw.id]
      )

      id = draw.id
      assert id in StuckDrawRedriver.redrive()
      assert_received {@reinserted, ^ref, _, %{draw_id: ^id, replaced: 0}}
    end
  end

  describe "a job that can still run the draw is left alone" do
    for {name, set} <- [
          {"available now", nil},
          {"scheduled within the worker's longest delay",
           "state = 'scheduled', scheduled_at = timezone('UTC', now()) + interval '100 seconds'"},
          {"retrying within the worker's longest delay",
           "state = 'retryable', attempt = 3, " <>
             "scheduled_at = timezone('UTC', now()) + interval '100 seconds'"},
          {"executing", "state = 'executing', attempted_at = timezone('UTC', now())"}
        ] do
      @set set
      test name do
        draw = freq_draw()
        job!(draw, @set)
        refute draw.id in StuckDrawRedriver.redrive()
        assert [[_, state, _, _]] = jobs(draw)
        refute state == "cancelled"
      end
    end

    test "the longest delay is the worker's backoff cap" do
      assert ObservationDrawWorker.max_delay_seconds() == 120

      assert Enum.max(for a <- 1..20, do: ObservationDrawWorker.backoff(%Oban.Job{attempt: a})) ==
               ObservationDrawWorker.max_delay_seconds()
    end
  end

  describe "overdue draws are reported every run" do
    test "whatever their jobs say, until they complete", %{ref: ref} do
      parked = freq_draw()
      job!(parked, "state = 'scheduled', scheduled_at = '2099-01-01 00:00:00'")
      runnable = landobs_draw()
      job!(runnable, nil)

      for _ <- 1..2 do
        StuckDrawRedriver.redrive()

        for {draw, protocol} <- [{parked, :frequency}, {runnable, :observation}] do
          id = draw.id
          since = DateTime.add(Quicknet.pub_time(draw.drand_round), 15 * 60)

          assert_received {@overdue, ^ref, %{count: 1},
                           %{draw_id: ^id, since: ^since, protocol: ^protocol}}
        end
      end
    end

    test "a cancelled row inserted by hand parks the draw but doesn't hide it", %{ref: ref} do
      draw = freq_draw()
      job!(draw, "state = 'cancelled', cancelled_at = now()")

      refute draw.id in StuckDrawRedriver.redrive()
      id = draw.id
      assert_received {@overdue, ^ref, _, %{draw_id: ^id, protocol: :frequency}}
    end

    test "a cancelled row with a forged reason elsewhere in errors doesn't hide it",
         %{ref: ref} do
      draw = landobs_draw()

      job!(
        draw,
        "state = 'cancelled', cancelled_at = now(), " <>
          ~s(errors = ARRAY['{"attempt": 1, "error": "execution refused: by hand"}'::jsonb])
      )

      StuckDrawRedriver.redrive()
      id = draw.id
      assert_received {@overdue, ^ref, _, %{draw_id: ^id, protocol: :observation}}
    end

    test "not before pub(R) + 15 minutes", %{ref: ref} do
      recent = freq_draw(10 * 60)
      StuckDrawRedriver.redrive()
      id = recent.id
      refute_received {@overdue, ^ref, _, %{draw_id: ^id}}
    end
  end
end
