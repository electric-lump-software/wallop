defmodule WallopWeb.Plugs.KeyRateLimitTest do
  use WallopWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import WallopCore.TestHelpers
  import WallopWeb.RateLimitHelpers

  alias WallopWeb.Plugs.KeyRateLimit
  alias WallopWeb.RateLimiter

  setup do
    RateLimiter.reset()
    Phoenix.PubSub.subscribe(WallopCore.PubSub, "rate_limit_pressure")

    test_pid = self()
    id = "key-rate-limit-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      for(k <- [:near_limit, :limited], do: [:wallop_web, :rate_limit, k]),
      fn [:wallop_web, :rate_limit, kind], %{count: 1}, meta, _ ->
        send(test_pid, {:telemetry, kind, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  defp with_limit(n) do
    key = create_api_key()

    key
    |> Ash.Changeset.for_update(:set_rate_limit, %{rate_limit_per_minute: n})
    |> Ash.update!(authorize?: false)

    key
  end

  defp call(key) do
    api_key = Ash.get!(WallopCore.Resources.ApiKey, key.id, authorize?: false)

    build_conn()
    |> Plug.Conn.assign(:api_key, api_key)
    |> KeyRateLimit.call([])
  end

  # Waits (generously) for exactly `n` messages for the key, then checks that
  # no further one turns up.
  defp pressure(key, n) do
    id = key.id

    received =
      for _ <- 1..n//1 do
        assert_receive {:rate_limit_pressure, %{api_key_id: ^id} = payload}, 1_000
        payload
      end

    refute_receive {:rate_limit_pressure, %{api_key_id: ^id}}, 100
    received
  end

  defp kinds(key, n), do: key |> pressure(n) |> Enum.map(& &1.kind) |> Enum.sort()

  defp telemetry_kinds(key) do
    receive do
      {:telemetry, kind, %{api_key_id: id}} when id == key.id -> [kind | telemetry_kinds(key)]
    after
      0 -> []
    end
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

  test "signals near-limit once at 80%" do
    await_fresh_window()
    key = with_limit(5)
    for _ <- 1..5, do: call(key)

    assert [%{kind: :near_limit, limit: 5, window_start: %DateTime{} = ws}] = pressure(key, 1)
    assert ws.second == 0
  end

  test "signals limited once per minute, with a telemetry event alongside" do
    await_fresh_window()
    key = with_limit(5)
    for _ <- 1..8, do: call(key)

    assert kinds(key, 2) == [:limited, :near_limit]
    # Telemetry handlers run in the calling process, so these are already here.
    assert Enum.sort(telemetry_kinds(key)) == [:limited, :near_limit]
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

    test "requests pass and nothing is signalled" do
      key = with_limit(1)

      capture_log(fn ->
        for _ <- 1..5, do: refute(call(key).halted)
      end)

      assert pressure(key, 0) == []
      assert telemetry_kinds(key) == []
    end
  end
end
