defmodule WallopCore.RateLimitEvents do
  @moduledoc "Records rate-limit pressure (ADR-0015 §6). Never fails the request that triggered it."

  require Logger
  require Ash.Query

  alias WallopCore.Log
  alias WallopCore.Resources.RateLimitEvent

  @spec record(Ecto.UUID.t(), :near_limit | :limited | :quota_limited, pos_integer()) :: :ok
  def record(api_key_id, kind, limit) do
    window_start =
      DateTime.utc_now() |> DateTime.to_unix() |> div(60) |> Kernel.*(60) |> DateTime.from_unix!()

    RateLimitEvent
    |> Ash.Changeset.for_create(:record, %{
      api_key_id: api_key_id,
      kind: kind,
      limit_per_minute: limit,
      window_start: window_start
    })
    |> Ash.create(domain: WallopCore.Domain, authorize?: false)
    |> case do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "RateLimitEvents: #{kind} for key #{Log.redact_id(api_key_id)} not recorded: #{inspect(error)}"
        )

        :ok
    end
  end

  @doc "Deletes events older than the retention period. Returns the number deleted."
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(now) do
    cutoff = DateTime.add(now, -retention_days() * 86_400, :second)

    stale = Ash.Query.filter(RateLimitEvent, window_start < ^cutoff)
    count = Ash.count!(stale, domain: WallopCore.Domain, authorize?: false)

    Ash.bulk_destroy!(stale, :destroy, %{},
      domain: WallopCore.Domain,
      authorize?: false,
      strategy: [:atomic, :stream],
      return_records?: false
    )

    count
  end

  defp retention_days do
    :wallop_core |> Application.get_env(__MODULE__, []) |> Keyword.get(:retention_days, 30)
  end
end
