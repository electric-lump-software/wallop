defmodule WallopWeb.Plugs.ProofPreLockRateLimitTest do
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers
  import WallopWeb.RateLimitHelpers

  alias WallopCore.Resources.Draw
  alias WallopWeb.Plugs.ProofPreLockRateLimit
  alias WallopWeb.Plugs.SelfCheckRateLimit

  setup do
    WallopWeb.RateLimiter.reset()
    await_fresh_window()
    :ok
  end

  describe "call/2" do
    test "no-op when params has no draw id", %{conn: conn} do
      for _ <- 1..200 do
        result = ProofPreLockRateLimit.call(conn, [])
        refute result.halted
      end
    end

    test "no-op for non-:open draw", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key, %{winner_count: 1})

      conn = %{conn | params: %{"id" => draw.id}}

      for _ <- 1..200 do
        result = ProofPreLockRateLimit.call(conn, [])
        refute result.halted
      end
    end

    test "allows up to max_attempts per IP per minute on :open draw", %{conn: conn} do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      conn = %{conn | params: %{"id" => draw.id}}

      for _ <- 1..ProofPreLockRateLimit.max_attempts() do
        result = ProofPreLockRateLimit.call(conn, [])
        refute result.halted
      end
    end

    test "blocks the (max_attempts + 1)th request within the window on :open draw", %{conn: conn} do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      conn = %{conn | params: %{"id" => draw.id}}

      for _ <- 1..ProofPreLockRateLimit.max_attempts(), do: ProofPreLockRateLimit.call(conn, [])

      result = ProofPreLockRateLimit.call(conn, [])
      assert result.halted
      assert result.status == 429
      [ra] = Plug.Conn.get_resp_header(result, "retry-after")
      assert String.to_integer(ra) in 1..60
    end

    test "separate IPs have separate quotas on :open draw", %{conn: conn} do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      a = %{conn | remote_ip: {1, 1, 1, 1}, params: %{"id" => draw.id}}
      b = %{conn | remote_ip: {2, 2, 2, 2}, params: %{"id" => draw.id}}

      for _ <- 1..ProofPreLockRateLimit.max_attempts(), do: ProofPreLockRateLimit.call(a, [])

      refute ProofPreLockRateLimit.call(b, []).halted
      assert ProofPreLockRateLimit.call(a, []).halted
    end

    test "exhausting pre-lock bucket does not deplete self-check bucket", %{conn: conn} do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      ip = "9.9.9.9"

      for _ <- 1..ProofPreLockRateLimit.max_attempts() do
        assert {:allow, _} =
                 WallopWeb.RateLimiter.hit(
                   "proof-pre-lock",
                   ip,
                   ProofPreLockRateLimit.max_attempts()
                 )
      end

      assert {:deny, _} =
               WallopWeb.RateLimiter.hit(
                 "proof-pre-lock",
                 ip,
                 ProofPreLockRateLimit.max_attempts()
               )

      assert SelfCheckRateLimit.check_rate(ip) == :ok

      check_conn = %{
        conn
        | remote_ip: {9, 9, 9, 9},
          params: %{"id" => draw.id, "entry_id" => "anything"}
      }

      result = SelfCheckRateLimit.call(check_conn, [])
      refute result.halted
    end

    test "non-existent draw id is not throttled (no enumeration oracle)", %{conn: conn} do
      conn = %{conn | params: %{"id" => "11111111-2222-3333-4444-555555555555"}}

      for _ <- 1..(ProofPreLockRateLimit.max_attempts() + 50) do
        result = ProofPreLockRateLimit.call(conn, [])
        refute result.halted
      end
    end
  end
end
