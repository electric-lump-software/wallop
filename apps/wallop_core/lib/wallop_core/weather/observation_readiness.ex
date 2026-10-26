defmodule WallopCore.Weather.ObservationReadiness do
  @moduledoc """
  Whether an observation-weather draw may be locked: the service that runs
  the `weather` queue says, through the database, whether it holds a usable
  Land Observations key.

  The lock may run in another service (an app that embeds wallop_core and
  only inserts jobs), so it can't ask its own environment. Instead:

    * a node whose core Oban runs the `weather` queue records
      `LandObsClient.key_configured?/0` at boot (`publish_at_boot/0`) and
      every 10 minutes (`WallopCore.Weather.ObservationReadinessWorker`, on
      the `weather` queue, so only such a node runs it);
    * a node without that queue never writes it;
    * a lock is allowed only if the record says ready and was written within
      the last #{div(30 * 60, 60)} minutes, on the database clock
      (`ready?/0`). A missing, false or stale record refuses the lock.

  The key stays the only switch: this record follows it and can't be set
  any other way.
  """

  require Ash.Query
  require Logger

  alias WallopCore.Entropy.LandObsClient
  alias WallopCore.Resources.ObservationReadiness, as: Record

  @stale_after_minutes 30

  @doc "How old the record may be, in minutes, before a lock refuses."
  @spec stale_after_minutes() :: pos_integer()
  def stale_after_minutes, do: @stale_after_minutes

  @doc "Whether an Oban config runs the `weather` queue."
  @spec weather_queue?(keyword()) :: boolean()
  def weather_queue?(oban_config) when is_list(oban_config) do
    case Keyword.get(oban_config, :queues) do
      queues when is_list(queues) -> Keyword.has_key?(queues, :weather)
      _ -> false
    end
  end

  @doc """
  Records this node's readiness if `oban_config` runs the `weather` queue;
  otherwise writes nothing. `:recorded` or `:skipped`.
  """
  @spec publish(keyword()) :: :recorded | :skipped
  def publish(oban_config) do
    if weather_queue?(oban_config) do
      record!(LandObsClient.key_configured?())
      :recorded
    else
      :skipped
    end
  end

  @doc """
  The boot write, run once under the application supervisor. Skipped when
  Oban is in a testing mode (its queues don't run). A failure is logged and
  left to the next 10-minute run; until then the lock fails closed.
  """
  @spec publish_at_boot() :: :recorded | :skipped | :failed
  def publish_at_boot do
    config = Application.get_env(:wallop_core, Oban, [])

    if Keyword.get(config, :testing, :disabled) == :disabled,
      do: publish(config),
      else: :skipped
  rescue
    e ->
      Logger.warning(
        "ObservationReadiness: boot write failed (#{inspect(e.__struct__)}); " <>
          "the next scheduled check will retry"
      )

      :failed
  end

  @doc false
  @spec record!(boolean()) :: Record.t()
  def record!(ready) when is_boolean(ready) do
    Record
    |> Ash.Changeset.for_create(:record, %{ready: ready})
    |> Ash.create!(authorize?: false)
  end

  @doc """
  True when the record says ready and was written no more than
  #{@stale_after_minutes} minutes ago by the database clock. One query.
  """
  @spec ready?() :: boolean()
  def ready? do
    Record
    |> Ash.Query.filter(
      ready == true and
        checked_at >=
          fragment(
            "(statement_timestamp() AT TIME ZONE 'UTC') - make_interval(mins => ?)",
            ^@stale_after_minutes
          )
    )
    |> Ash.exists?(authorize?: false)
  end
end
