defmodule WallopWeb.Plugs.EdgeGuardTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import ExUnit.CaptureLog
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

  defp with_both(secret, previous),
    do: Application.put_env(:wallop_web, EdgeGuard, secret: secret, previous_secret: previous)

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

  test "while a previous secret is set, both the current and previous values pass" do
    with_both("new-s3cret-value", "old-s3cret-value")

    for header <- ["new-s3cret-value", "old-s3cret-value"] do
      conn = call(:get, "/api/v1/draws", header)
      refute conn.halted
      assert get_req_header(conn, "x-edge-secret") == []
    end
  end

  test "while a previous secret is set, any other value is refused" do
    with_both("new-s3cret-value", "old-s3cret-value")

    for header <- ["guess", "", nil] do
      {conn, _log} = with_log(fn -> call(:get, "/api/v1/draws", header) end)
      assert conn.halted
      assert conn.status == 403
    end
  end

  test "a previous secret alone does not switch the guard on or replace the current one" do
    Application.put_env(:wallop_web, EdgeGuard, secret: nil, previous_secret: "old-s3cret-value")
    refute call(:get, "/api/v1/draws", nil).halted
  end

  test "a wrong header is refused with 403" do
    with_secret("s3cret-value")
    {conn, _log} = with_log(fn -> call(:get, "/api/v1/draws", "guess") end)
    assert conn.halted
    assert conn.status == 403
  end

  test "a missing header is refused with 403" do
    with_secret("s3cret-value")
    {conn, _log} = with_log(fn -> call(:post, "/api/v1/draws", nil) end)
    assert conn.halted
    assert conn.status == 403
  end

  test "GET /health is exempt, for the platform's internal healthcheck" do
    with_secret("s3cret-value")
    refute call(:get, "/health", nil).halted
    health = call(:get, "/health", "anything")
    refute health.halted
    assert get_req_header(health, "x-edge-secret") == []

    capture_log(fn ->
      assert call(:post, "/health", nil).status == 403
      assert call(:get, "/api/v1/health", nil).status == 403
    end)
  end

  test "a blank configured secret does not admit an empty header" do
    with_secret("")
    {conn, _log} = with_log(fn -> call(:get, "/api/v1/draws", "") end)
    assert conn.halted
    assert conn.status == 403
  end

  test "two secret headers are refused even if one matches" do
    with_secret("s3cret-value")

    base = conn(:get, "/api/v1/draws")
    headers = [{"x-edge-secret", "s3cret-value"}, {"x-edge-secret", "s3cret-value"}]

    {conn, _log} =
      with_log(fn ->
        EdgeGuard.call(%{base | req_headers: headers}, EdgeGuard.init([]))
      end)

    assert conn.status == 403
  end

  test "a refusal is logged without the header value" do
    with_secret("s3cret-value")
    log = capture_log(fn -> call(:get, "/api/v1/draws", "guess") end)
    assert log =~ "edge guard refused request: GET /api/v1/draws"
    refute log =~ "guess"
  end
end
