defmodule WallopWeb.Plugs.KeyRateLimitTest do
  use WallopWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import WallopCore.TestHelpers
  import WallopWeb.RateLimitHelpers

  alias WallopCore.Resources.RateLimitEvent
  alias WallopWeb.Plugs.KeyRateLimit
  alias WallopWeb.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  defp with_limit(n) do
    key = create_api_key()

    key
    |> Ash.Changeset.for_update(:update_tier, %{rate_limit_per_minute: n})
    |> Ash.update!(authorize?: false)

    key
  end

  defp call(key) do
    api_key = Ash.get!(WallopCore.Resources.ApiKey, key.id, authorize?: false)

    build_conn()
    |> Plug.Conn.assign(:api_key, api_key)
    |> KeyRateLimit.call([])
  end

  defp events(key) do
    RateLimitEvent
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.api_key_id == key.id))
    |> Enum.map(& &1.kind)
    |> Enum.sort()
  end

  test "no key assigned passes through" do
    refute KeyRateLimit.call(build_conn(), []).halted
  end

  test "a key without a setting gets 60 a minute" do
    assert KeyRateLimit.limit_for(%{rate_limit_per_minute: nil}) == 60
  end

  test "a key's own limit applies, then 429 with Retry-After and a JSON:API body" do
    await_fresh_window()
    key = with_limit(5)
    for _ <- 1..5, do: refute(call(key).halted)

    conn = call(key)
    assert conn.status == 429
    [ra] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(ra) in 1..60

    assert %{"errors" => [%{"code" => "rate_limit_exceeded", "meta" => %{"limit" => 5}}]} =
             Jason.decode!(conn.resp_body)
  end

  test "keys count independently" do
    await_fresh_window()
    a = with_limit(2)
    b = with_limit(2)
    for _ <- 1..2, do: call(a)

    assert call(a).halted
    refute call(b).halted
  end

  test "records near-limit once at 80% and limited once per minute" do
    await_fresh_window()
    key = with_limit(5)
    for _ <- 1..5, do: call(key)
    assert events(key) == [:near_limit]

    for _ <- 1..3, do: call(key)
    assert events(key) == [:limited, :near_limit]
  end

  test "near threshold is 80% rounded up, at least 1" do
    assert KeyRateLimit.near_threshold(60) == 48
    assert KeyRateLimit.near_threshold(5) == 4
    assert KeyRateLimit.near_threshold(1) == 1
  end

  describe "when the counter store errors" do
    setup do
      # The Redis backend is not started in tests, so every hit is a store
      # error and fails open as {:allow, 0}.
      previous = Application.get_env(:wallop_web, RateLimiter, [])
      Application.put_env(:wallop_web, RateLimiter, Keyword.put(previous, :backend, :redis))
      on_exit(fn -> Application.put_env(:wallop_web, RateLimiter, previous) end)
    end

    test "requests pass and no event is recorded" do
      key = with_limit(1)

      capture_log(fn ->
        for _ <- 1..5, do: refute(call(key).halted)
      end)

      assert events(key) == []
    end
  end
end
