defmodule WallopWeb.RateLimitSignal do
  @moduledoc """
  Announces rate-limit pressure. Nothing is stored: attach a handler if you
  want a history.

  Each call emits a telemetry event, `[:wallop_web, :rate_limit, kind]`, with
  measurements `%{count: 1}` and metadata `%{api_key_id: id, limit: limit}`,
  and broadcasts `{:rate_limit_pressure, payload}` on the `"rate_limit_pressure"`
  topic of `WallopCore.PubSub`. The payload is a plain map:
  `%{api_key_id: id, kind: kind, limit: limit, window_start: datetime}`, where
  `window_start` is the clock-aligned minute.

  `kind` is `:near_limit`, `:limited` or `:quota_limited`. Callers dedupe to
  once per key, kind and minute, and never call this on a store error.

  Never fails or slows the request that triggered it.
  """

  require Logger

  alias WallopCore.Log

  @topic "rate_limit_pressure"

  @type kind :: :near_limit | :limited | :quota_limited

  @doc "The PubSub topic pressure messages are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @spec emit(Ecto.UUID.t(), kind(), pos_integer()) :: :ok
  def emit(api_key_id, kind, limit) when kind in [:near_limit, :limited, :quota_limited] do
    :telemetry.execute(
      [:wallop_web, :rate_limit, kind],
      %{count: 1},
      %{api_key_id: api_key_id, limit: limit}
    )

    payload = %{
      api_key_id: api_key_id,
      kind: kind,
      limit: limit,
      window_start: window_start()
    }

    try do
      case Phoenix.PubSub.broadcast(WallopCore.PubSub, @topic, {:rate_limit_pressure, payload}) do
        :ok -> :ok
        {:error, reason} -> warn(api_key_id, kind, reason)
      end
    catch
      kind_of_failure, reason ->
        warn(api_key_id, kind, {kind_of_failure, reason})
    end

    :ok
  end

  defp warn(api_key_id, kind, reason) do
    Logger.warning(
      "RateLimitSignal: #{kind} for key #{Log.redact_id(api_key_id)} not broadcast: #{inspect(reason)}"
    )
  end

  defp window_start do
    DateTime.utc_now() |> DateTime.to_unix() |> div(60) |> Kernel.*(60) |> DateTime.from_unix!()
  end
end
