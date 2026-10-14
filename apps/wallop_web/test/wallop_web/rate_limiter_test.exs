defmodule WallopWeb.RateLimiterTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import WallopWeb.RateLimitHelpers

  alias WallopWeb.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  defp id, do: "t-#{System.unique_integer([:positive])}"

  test "allows up to the limit, then denies with a Retry-After of 1..60" do
    await_fresh_window()
    k = id()
    assert {:allow, 1} = RateLimiter.hit("b", k, 2)
    assert {:allow, 2} = RateLimiter.hit("b", k, 2)
    assert {:deny, s} = RateLimiter.hit("b", k, 2)
    assert s in 1..60
  end

  test "buckets and ids are independent" do
    await_fresh_window()
    k = id()
    assert {:allow, 1} = RateLimiter.hit("a", k, 1)
    assert {:allow, 1} = RateLimiter.hit("b", k, 1)
    assert {:allow, 1} = RateLimiter.hit("a", id(), 1)
  end

  test "Retry-After rounds up and is never 0 or above 60" do
    assert RateLimiter.retry_after_seconds(0) == 1
    assert RateLimiter.retry_after_seconds(1) == 1
    assert RateLimiter.retry_after_seconds(999) == 1
    assert RateLimiter.retry_after_seconds(1001) == 2
    assert RateLimiter.retry_after_seconds(60_000) == 60
    assert RateLimiter.retry_after_seconds(90_000) == 60
  end

  test "the Redis backend without a URL refuses to start" do
    assert_raise ArgumentError, ~r/REDIS_URL/, fn ->
      RateLimiter.child_spec(backend: :redis, redis_url: nil)
    end
  end

  test "a store error allows the request and emits telemetry" do
    # The Redis limiter isn't started in this test, so every call errors.
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:wallop_web, :rate_limiter, :backend_error]
      ])

    assert {:allow, 0} = RateLimiter.hit("b", id(), 1, :redis)

    assert_received {[:wallop_web, :rate_limiter, :backend_error], ^ref, %{count: 1},
                     %{backend: :redis, bucket: "b"}}
  end

  test "a hung store allows the request quickly" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    # Accept connections and never reply.
    acceptor =
      spawn_link(fn ->
        accept_forever = fn loop ->
          case :gen_tcp.accept(listener) do
            {:ok, _socket} -> loop.(loop)
            {:error, _} -> :ok
          end
        end

        accept_forever.(accept_forever)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.unlink(acceptor)
    end)

    start_supervised!(
      RateLimiter.child_spec(backend: :redis, redis_url: "redis://127.0.0.1:#{port}")
    )

    {micros, result} = :timer.tc(fn -> RateLimiter.hit("b", id(), 1, :redis) end)

    assert {:allow, 0} = result
    assert micros < 500_000
  end

  @tag :redis
  test "the Redis backend counts and denies like ETS" do
    await_fresh_window()
    url = System.fetch_env!("REDIS_URL")
    start_supervised!(RateLimiter.child_spec(backend: :redis, redis_url: url))
    k = id()
    assert {:allow, 1} = RateLimiter.hit("b", k, 1, :redis)
    assert {:deny, s} = RateLimiter.hit("b", k, 1, :redis)
    assert s in 1..60
  end

  @tag :redis
  test "an unreachable Redis allows requests" do
    start_supervised!(RateLimiter.child_spec(backend: :redis, redis_url: "redis://127.0.0.1:1"))
    assert {:allow, 0} = RateLimiter.hit("b", id(), 1, :redis)
    assert {:allow, 0} = RateLimiter.hit("b", id(), 1, :redis)
  end
end
