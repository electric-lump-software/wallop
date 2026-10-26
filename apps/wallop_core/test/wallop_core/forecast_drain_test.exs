defmodule WallopCore.ForecastDrainTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.ForecastDrain
  alias WallopCore.Repo
  alias WallopCore.Resources.Draw

  @worker "WallopCore.Entropy.EntropyWorker"

  defp insert_forecast_job!(draw_id, state) do
    Repo.query!(
      """
      INSERT INTO oban_jobs (state, queue, worker, args, max_attempts, scheduled_at, inserted_at)
      VALUES ($1::oban_job_state, 'entropy', $2, $3, 10, now(), now())
      """,
      [state, @worker, %{"draw_id" => draw_id}]
    )
  end

  defp job_states do
    %{rows: rows} =
      Repo.query!("SELECT state::text FROM oban_jobs WHERE worker = $1 ORDER BY id", [@worker])

    List.flatten(rows)
  end

  setup do
    ensure_infrastructure_key()
    %{key: create_api_key()}
  end

  test "report counts stranded forecast draws and live forecast jobs", %{key: key} do
    assert ForecastDrain.report() == %{stranded_draws: 0, live_forecast_jobs: 0}

    stranded = put_retired_forecast_draw!(key, :awaiting_entropy)
    _done = put_retired_forecast_draw!(key, :completed)
    _v6 = create_draw(key)
    insert_forecast_job!(stranded.id, "scheduled")
    insert_forecast_job!(stranded.id, "completed")

    assert ForecastDrain.report() == %{stranded_draws: 1, live_forecast_jobs: 1}
  end

  test "drain fails every stranded forecast draw with the fixed reason and cancels live jobs",
       %{key: key} do
    awaiting = put_retired_forecast_draw!(key, :awaiting_entropy)
    pending = put_retired_forecast_draw!(key, :pending_entropy)
    completed = put_retired_forecast_draw!(key, :completed)
    v6 = create_draw(key)
    insert_forecast_job!(awaiting.id, "scheduled")
    insert_forecast_job!(pending.id, "retryable")
    insert_forecast_job!(completed.id, "completed")

    result = ForecastDrain.drain()

    assert Enum.sort(result.failed) == Enum.sort([awaiting.id, pending.id])
    assert result.not_failed == []
    assert result.jobs_cancelled == 2

    for id <- [awaiting.id, pending.id] do
      draw = Ash.get!(Draw, id, authorize?: false)
      assert draw.status == :failed
      assert draw.failure_reason == "forecast_retired"
    end

    assert Ash.get!(Draw, completed.id, authorize?: false).status == :completed
    assert Ash.get!(Draw, v6.id, authorize?: false).status == :awaiting_entropy
    assert Enum.sort(job_states()) == ["cancelled", "cancelled", "completed"]

    assert ForecastDrain.report() == %{stranded_draws: 0, live_forecast_jobs: 0}
    assert ForecastDrain.drain() == %{failed: [], not_failed: [], jobs_cancelled: 0}
  end

  test "a stranded draw in locked is returned under not_failed, untouched", %{key: key} do
    locked = put_retired_forecast_draw!(key, :locked)

    assert ForecastDrain.report().stranded_draws == 1

    assert ForecastDrain.drain() == %{
             failed: [],
             not_failed: [{locked.id, "locked"}],
             jobs_cancelled: 0
           }

    assert Ash.get!(Draw, locked.id, authorize?: false).status == :locked
  end
end
