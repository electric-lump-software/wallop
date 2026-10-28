defmodule WallopCore.Telemetry.ObanShutdownHandler do
  @moduledoc """
  Logs an error when an Oban queue shuts down with jobs still running.

  Oban emits `[:oban, :queue, :shutdown]` once per queue when the node stops.
  `orphaned` lists the ids of jobs that were still executing when the shutdown
  grace period ran out. Those jobs stay `executing` until Lifeline rescues them,
  so a non-empty list means a deploy cut work short. A clean shutdown logs
  nothing. Only the queue name and the Oban job ids are logged.
  """

  require Logger

  @event [:oban, :queue, :shutdown]

  @doc "Attaches the handler. Safe to call more than once."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(__MODULE__, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(@event, _measurements, %{orphaned: [_ | _] = orphaned, queue: queue}, _config) do
    Logger.error(
      "Oban queue #{queue} shut down with orphaned jobs: #{inspect(orphaned, charlists: :as_lists)}"
    )
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
