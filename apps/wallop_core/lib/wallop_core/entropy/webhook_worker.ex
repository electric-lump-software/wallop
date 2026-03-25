defmodule WallopCore.Entropy.WebhookWorker do
  @moduledoc """
  Oban worker that delivers webhook notifications when a draw completes.

  Full implementation in Task 9.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 10

  @impl true
  def perform(%Oban.Job{args: _args}) do
    # Full implementation in Task 9
    :ok
  end
end
