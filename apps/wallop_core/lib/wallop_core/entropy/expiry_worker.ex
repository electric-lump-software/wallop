defmodule WallopCore.Entropy.ExpiryWorker do
  @moduledoc """
  Oban cron worker that expires open draws older than 90 days.
  """
  use Oban.Worker, queue: :default

  require Ash.Query
  require Logger

  @max_age_days 90

  @impl true
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@max_age_days * 86_400, :second)

    WallopCore.Resources.Draw
    |> Ash.Query.filter(status == :open and inserted_at < ^cutoff)
    |> Ash.read!(domain: WallopCore.Domain, authorize?: false)
    |> Enum.each(fn draw ->
      case draw
           |> Ash.Changeset.for_update(:expire, %{})
           |> Ash.update(domain: WallopCore.Domain, authorize?: false) do
        {:ok, _} ->
          Logger.info("ExpiryWorker: expired draw #{draw.id}")

        {:error, reason} ->
          Logger.warning("ExpiryWorker: failed to expire draw #{draw.id}: #{inspect(reason)}")
      end
    end)

    :ok
  end
end
