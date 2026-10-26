defmodule WallopCore.ForecastDrain do
  @moduledoc """
  The deploy gate for retiring forecast-weather draws.

  A retired forecast draw has no lock schema (a NULL
  `(lock_schema_version, entropy_composition)` pair). Nothing in this build
  can run one: its worker, its queue and its execute actions are gone, and
  the re-drive reads only `lock_schema_version = '6'` draws. A forecast
  lock that committed on the old code just before the migration would
  otherwise sit in `awaiting_entropy` for ever, unseen.

    * `report/0` (read-only) counts those stranded draws and the live jobs
      of the old forecast worker. Run it before the deploy; both should be
      0.
    * `drain/0` runs after the deploy, once the last old container has
      stopped. It fails every stranded draw through `:mark_failed` with
      the fixed reason `"forecast_retired"`, then cancels any live job of
      the old forecast worker. Failing a draw with no lock schema is
      allowed at any time: no v6 deadline applies to it. A stranded draw
      in `locked` is not failed (`:mark_failed` doesn't take that status)
      and is returned under `:not_failed` for a person to look at; the
      forecast lock never left a draw there.

  `drain/0` writes through the draw's actions, so it must run inside the
  running service (`bin/wallop rpc "WallopCore.Release.drain_retired_forecast()"`),
  where Oban is up to take each failed draw's webhook. Run it once, after
  the last container on the old code has stopped. With secrets from
  Infisical a plain shell has no `RELEASE_COOKIE`; `MIGRATING.md` says how
  to run it. Both are wrapped in `WallopCore.Release`.
  """

  require Logger

  alias WallopCore.Log
  alias WallopCore.Repo
  alias WallopCore.Resources.Draw

  @reason "forecast_retired"
  @worker "WallopCore.Entropy.EntropyWorker"
  @live_states ~w(available scheduled executing retryable suspended)

  @stranded_sql """
  SELECT id::text, status FROM draws
  WHERE lock_schema_version IS NULL AND entropy_composition IS NULL
    AND status IN ('locked', 'awaiting_entropy', 'pending_entropy')
  ORDER BY inserted_at, id
  """

  @live_jobs_sql """
  SELECT count(*) FROM oban_jobs WHERE worker = $1 AND state::text = ANY($2)
  """

  @doc "The fixed failure reason `drain/0` records."
  @spec reason() :: String.t()
  def reason, do: @reason

  @doc """
  Stranded forecast draws (no lock schema, still in `locked`,
  `awaiting_entropy` or `pending_entropy`) and live jobs of the old
  forecast worker. Writes nothing.
  """
  @spec report() :: %{stranded_draws: non_neg_integer(), live_forecast_jobs: non_neg_integer()}
  def report do
    %{rows: [[jobs]]} = Repo.query!(@live_jobs_sql, [@worker, @live_states])
    %{stranded_draws: length(stranded()), live_forecast_jobs: jobs}
  end

  @doc """
  Fails every stranded forecast draw with reason `"forecast_retired"`,
  then cancels the old forecast worker's live jobs. Running it again does
  nothing more.
  """
  @spec drain() :: %{
          failed: [String.t()],
          not_failed: [{String.t(), String.t() | term()}],
          jobs_cancelled: non_neg_integer()
        }
  def drain do
    {failed, not_failed} =
      stranded()
      |> Enum.map(fn {id, status} -> {id, status, fail(id)} end)
      |> Enum.split_with(fn {_id, _status, result} -> result == :ok end)

    %{
      failed: Enum.map(failed, fn {id, _, _} -> id end),
      not_failed: Enum.map(not_failed, fn {id, status, _} -> {id, status} end),
      jobs_cancelled: cancel_jobs()
    }
  end

  defp stranded do
    %{rows: rows} = Repo.query!(@stranded_sql, [])
    Enum.map(rows, fn [id, status] -> {id, status} end)
  end

  defp fail(id) do
    # A read error fails this draw only; the drain carries on with the rest.
    result =
      with {:ok, draw} <- Ash.get(Draw, id, authorize?: false) do
        draw
        |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: @reason})
        |> Ash.update(authorize?: false)
      end

    case result do
      {:ok, _draw} ->
        :ok

      {:error, error} ->
        Logger.error(
          "ForecastDrain: draw #{Log.redact_id(id)} could not be failed: #{inspect(error)}"
        )

        :error
    end
  end

  defp cancel_jobs do
    import Ecto.Query

    query = from(j in Oban.Job, where: j.worker == @worker and j.state in @live_states)
    {:ok, count} = Oban.cancel_all_jobs(query)
    count
  end
end
