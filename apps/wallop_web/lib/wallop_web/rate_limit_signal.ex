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

  `kind` is `:near_limit` or `:limited`. Callers dedupe to
  once per key, kind and minute, and never call this on a store error.

  Never fails the request that triggered it, and never waits on PubSub: the
  telemetry event is local, and the broadcast runs in a task under
  `WallopWeb.TaskSupervisor`.
  """

  require Logger

  alias WallopCore.Log

  @topic "rate_limit_pressure"

  @type kind :: :near_limit | :limited

  @spec emit(Ecto.UUID.t(), kind(), pos_integer()) :: :ok
  def emit(api_key_id, kind, limit) when kind in [:near_limit, :limited] do
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

    spawn_broadcast(api_key_id, kind, payload)
    :ok
  end

  # The broadcast can block on a slow Redis adapter, so it runs off the
  # request process. If even starting the task fails, the signal is dropped.
  defp spawn_broadcast(api_key_id, kind, payload) do
    Task.Supervisor.start_child(WallopWeb.TaskSupervisor, fn ->
      broadcast(api_key_id, kind, payload)
    end)
  catch
    _class, _reason -> :ok
  end

  defp broadcast(api_key_id, kind, payload) do
    case Phoenix.PubSub.broadcast(WallopCore.PubSub, @topic, {:rate_limit_pressure, payload}) do
      :ok -> :ok
      {:error, reason} -> warn(api_key_id, kind, reason)
    end
  catch
    class, reason -> warn(api_key_id, kind, {class, reason})
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
