defmodule WallopWeb.EndpointRemoteIpTest do
  @moduledoc """
  Regression: confirms that `conn.remote_ip` is rewritten from the
  trusted proxy header when the request hits the endpoint pipeline.

  This is the integration that closes the per-IP rate limit hole: the
  rate-limit plugs key on `conn.remote_ip`, and behind a CDN/edge layer
  the TCP source IP is always the edge — so without a rewrite, every
  legitimate request appears to come from the same handful of edge IPs
  and the per-IP limit is meaningless.

  Treating the header as authoritative is safe **iff** the edge →
  origin path is protected so an attacker cannot bypass the edge and
  supply their own header value. That guard is a deploy-platform
  concern, not an app concern.
  """
  use WallopWeb.ConnCase, async: true

  test "CF-Connecting-IP rewrites conn.remote_ip" do
    # /health is the simplest existing endpoint; hits the full plug
    # pipeline including RemoteIp.
    conn =
      build_conn()
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> put_req_header("cf-connecting-ip", "203.0.113.42")
      |> get("/health")

    # The HealthController doesn't expose remote_ip, but RemoteIp runs
    # in the endpoint pipeline before the controller. We can read it
    # off the conn that comes back.
    assert conn.remote_ip == {203, 0, 113, 42}
  end

  test "CF-Connecting-IP with IPv6 rewrites conn.remote_ip" do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> put_req_header("cf-connecting-ip", "2001:db8::1")
      |> get("/health")

    assert conn.remote_ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
  end

  test "no CF-Connecting-IP header leaves conn.remote_ip as the TCP source" do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> get("/health")

    assert conn.remote_ip == {10, 0, 0, 1}
  end

  test "malformed CF-Connecting-IP leaves conn.remote_ip as the TCP source" do
    # Defensive: RemoteIp ignores values it can't parse rather than
    # raising, so a malformed header from a misbehaving upstream is a
    # logged anomaly, not a 500.
    conn =
      build_conn()
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> put_req_header("cf-connecting-ip", "not-an-ip")
      |> get("/health")

    assert conn.remote_ip == {10, 0, 0, 1}
  end
end
