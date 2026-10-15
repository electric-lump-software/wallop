defmodule WallopCore.Entropy.ExpiryWorker do
  @moduledoc """
  Oban cron worker that expires open draws older than 90 days.
  """
  use Oban.Worker, queue: :default

  require Ash.Query
  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias WallopCore.Log

  @max_age_days 90

  @impl true
  def perform(_job) do
    Tracer.with_span "expiry_worker.run" do
      cutoff = DateTime.add(DateTime.utc_now(), -@max_age_days * 86_400, :second)

      draws =
        WallopCore.Resources.Draw
        |> Ash.Query.filter(status == :open and inserted_at < ^cutoff)
        |> Ash.read!(domain: WallopCore.Domain, authorize?: false)

      Tracer.set_attributes(%{"expiry.candidates" => length(draws)})

      Enum.each(draws, fn draw ->
        case draw
             |> Ash.Changeset.for_update(:expire, %{})
             |> Ash.update(domain: WallopCore.Domain, authorize?: false) do
          {:ok, _expired_draw} ->
            Logger.info("ExpiryWorker: expired draw #{Log.redact_id(draw.id)}")

          {:error, reason} ->
            Logger.warning(
              "ExpiryWorker: failed to expire draw #{Log.redact_id(draw.id)}: #{inspect(reason)}"
            )
        end
      end)

      :ok
    end
  end
end
