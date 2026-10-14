defmodule WallopWeb.Plugs.EdgeGuardTest do
  # Not async: tests change the application env the plug reads.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias WallopWeb.Plugs.EdgeGuard

  setup do
    previous = Application.get_env(:wallop_web, EdgeGuard)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:wallop_web, EdgeGuard)
  defp restore(value), do: Application.put_env(:wallop_web, EdgeGuard, value)

  defp with_secret(secret), do: Application.put_env(:wallop_web, EdgeGuard, secret: secret)

  defp call(method, path, header) do
    conn = conn(method, path)
    conn = if header, do: put_req_header(conn, "x-edge-secret", header), else: conn
    EdgeGuard.call(conn, EdgeGuard.init([]))
  end

  test "with no secret configured, every request passes" do
    with_secret(nil)
    refute call(:get, "/api/v1/draws", nil).halted
  end

  test "a matching header passes, and the header is removed" do
    with_secret("s3cret-value")
    conn = call(:get, "/api/v1/draws", "s3cret-value")
    refute conn.halted
    assert get_req_header(conn, "x-edge-secret") == []
  end

  test "a wrong header is refused with 403" do
    with_secret("s3cret-value")
    conn = call(:get, "/api/v1/draws", "guess")
    assert conn.halted
    assert conn.status == 403
  end

  test "a missing header is refused with 403" do
    with_secret("s3cret-value")
    conn = call(:post, "/api/v1/draws", nil)
    assert conn.halted
    assert conn.status == 403
  end

  test "GET /health is exempt, for the platform's internal healthcheck" do
    with_secret("s3cret-value")
    refute call(:get, "/health", nil).halted
    assert call(:post, "/health", nil).status == 403
    assert call(:get, "/api/v1/health", nil).status == 403
  end
end
