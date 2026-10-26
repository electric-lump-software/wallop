defmodule WallopCore.Weather.ObservationReadinessWorker do
  @moduledoc """
  Every 10 minutes (cron, in core's own Oban config), records whether this
  node can fetch Land Observations readings
  (`WallopCore.Weather.ObservationReadiness`). It runs on the `weather`
  queue, so only a node that runs that queue, and so makes the fetches,
  ever runs it.
  """
  use Oban.Worker,
    queue: :weather,
    max_attempts: 3,
    unique: [period: 60]

  alias WallopCore.Weather.ObservationReadiness

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    ObservationReadiness.publish(Application.get_env(:wallop_core, Oban, []))
    :ok
  end
end
