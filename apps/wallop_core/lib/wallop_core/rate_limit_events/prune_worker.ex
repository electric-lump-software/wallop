defmodule WallopCore.RateLimitEvents.PruneWorker do
  @moduledoc "Daily: deletes rate-limit events older than the retention period."
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    WallopCore.RateLimitEvents.prune(DateTime.utc_now())
    :ok
  end
end
