defmodule WallopCore.Telemetry.EctoHandler do
  @moduledoc """
  Custom Ecto telemetry handler that delegates to OpentelemetryEcto
  but skips Oban's internal polling queries (oban_jobs, oban_peers, etc).
  """

  @oban_tables ~w(oban_jobs oban_peers oban_producers)

  def setup(prefix, opts \\ []) do
    :telemetry.attach(
      {__MODULE__, prefix},
      prefix ++ [:query],
      &__MODULE__.handle_event/4,
      %{prefix: prefix, opts: opts}
    )
  end

  def handle_event(_event, _measurements, %{source: source}, _config)
      when source in @oban_tables,
      do: :ok

  def handle_event(event, measurements, metadata, %{prefix: prefix, opts: opts}) do
    config = [
      time_unit: Keyword.get(opts, :time_unit, :microsecond),
      span_prefix: Keyword.get(opts, :span_prefix, Enum.join(prefix, ".")),
      additional_attributes: Keyword.get(opts, :additional_attributes, %{}),
      db_statement: Keyword.get(opts, :db_statement, :disabled)
    ]

    OpentelemetryEcto.handle_event(event, measurements, metadata, config)
  end
end
