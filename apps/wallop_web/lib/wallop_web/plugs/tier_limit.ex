defmodule WallopWeb.Plugs.TierLimit do
  @moduledoc """
  Enforces the actor API key's monthly draw limit on draw creation.

  Runs after authentication on `POST /api/v1/draws`. If the actor has a
  `monthly_draw_limit` set and `monthly_draw_count` is at or above it,
  responds with HTTP 429 and a JSON error containing the tier name and
  upgrade URL.

  API keys without a `monthly_draw_limit` (nil) are unlimited and pass
  through. The consumer application is responsible for setting tier
  metadata on keys via the `update_tier` action when subscriptions change.
  """

  alias WallopCore.RateLimitEvents
  alias WallopWeb.RateLimiter
  alias WallopWeb.RateLimitResponse

  @upgrade_url "https://nether.wallop.run/pricing"

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: ["draws" | _]} = conn, _opts) do
    enforce(conn)
  end

  def call(conn, _opts), do: conn

  defp enforce(conn) do
    case conn.assigns[:api_key] do
      nil ->
        conn

      api_key ->
        case check_limit(api_key) do
          :ok -> conn
          {:exceeded, tier, limit} -> render_429(conn, api_key, tier, limit)
        end
    end
  end

  defp check_limit(%{monthly_draw_limit: nil}), do: :ok

  defp check_limit(%{monthly_draw_limit: limit} = api_key) do
    if effective_count(api_key) >= limit do
      {:exceeded, api_key.tier, limit}
    else
      :ok
    end
  end

  defp effective_count(%{count_reset_at: nil}), do: 0

  defp effective_count(%{count_reset_at: reset_at, monthly_draw_count: count}) do
    if DateTime.compare(DateTime.utc_now(), reset_at) != :lt do
      0
    else
      count || 0
    end
  end

  defp render_429(conn, api_key, tier, limit) do
    tier_label = tier || "current"
    retry_after = max(1, DateTime.diff(api_key.count_reset_at, DateTime.utc_now(), :second))

    # First quota refusal this minute only; false on a store error too.
    if RateLimiter.first_this_window?("quota-limited-event", api_key.id),
      do: RateLimitEvents.record(api_key.id, :quota_limited, limit)

    RateLimitResponse.send_429(
      conn,
      retry_after,
      "tier_limit_exceeded",
      "Monthly draw limit reached on the #{tier_label} tier (#{limit} draws/month). " <>
        "Upgrade at #{@upgrade_url}",
      %{tier: tier_label, limit: limit, upgrade_url: @upgrade_url}
    )
  end
end
