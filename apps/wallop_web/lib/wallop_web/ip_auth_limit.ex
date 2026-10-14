defmodule WallopWeb.IpAuthLimit do
  @moduledoc """
  Per-IP limit on failed API authentications (ADR-0015).

  Authentication runs first. Only failures count, so a valid key is never
  refused here, even from an IP someone else has exhausted. Once an IP has
  `max_failures/0` failures in the current minute, further failures get a
  429 instead of a 401.

  A key that still needs the slow bcrypt check is counted before bcrypt runs
  and refused without running it when the IP is over the limit. That attempt
  is counted once and not again if bcrypt fails; a successful bcrypt
  verification also uses a slot, with no refund.

  `RateLimiter.hit/3` increments and compares in one step, so a concurrent
  burst of bad keys from one IP is capped at the limit. IPv6 addresses are
  counted per /64, since one host usually holds a whole /64.
  """

  alias WallopWeb.RateLimiter

  @bucket "ip-auth"

  @doc """
  Counts one authentication attempt against `ip`. `{:deny, retry_after}` means
  the IP is over its limit; the denial is reported on
  `[:wallop_web, :ip_auth_limit, :denied]` (no address in the metadata).
  """
  @spec record_failure(:inet.ip_address()) :: :ok | {:deny, 1..60}
  def record_failure(ip) do
    case RateLimiter.hit(@bucket, bucket_id(ip), max_failures()) do
      {:allow, _count} ->
        :ok

      {:deny, retry_after} ->
        :telemetry.execute([:wallop_web, :ip_auth_limit, :denied], %{count: 1}, %{})
        {:deny, retry_after}
    end
  end

  @spec bucket_id(:inet.ip_address()) :: String.t()
  def bucket_id({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> List.to_string()

  def bucket_id({a, b, c, d, _, _, _, _}),
    do: ({a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> List.to_string()) <> "/64"

  @spec max_failures() :: pos_integer()
  def max_failures do
    :wallop_web
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_failures_per_minute, 30)
  end
end
