defmodule WallopWeb.Plugs.ProofPreLockRateLimitTest do
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Resources.Draw
  alias WallopWeb.Plugs.ProofPreLockRateLimit
  alias WallopWeb.Plugs.SelfCheckRateLimit

  setup do
    ProofPreLockRateLimit.reset()
    :ok
  end

  describe "call/2" do
    test "no-op when params has no draw id", %{conn: conn} do
      # Many requests, no id — must not rate-limit.
      for _ <- 1..200 do
        result = ProofPreLockRateLimit.call(conn, [])
        refute result.halted
      end
    end

    test "no-op for non-:open draw", %{conn: conn} do
      api_key = create_api_key()
      # `create_draw` runs through to :awaiting_entropy (locked).
      draw = create_draw(api_key, %{winner_count: 1})

      conn = %{conn | params: %{"id" => draw.id}}

      # Many requests against a locked draw — must not be throttled
      # by THIS plug. Different cache story / different bucket.
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

    test "table is distinct from SelfCheckRateLimit's table", %{conn: _conn} do
      # Existence/identity check: the two plugs must NOT share an ETS
      # table — otherwise their budgets would fight on the same key
      # space. This is a structural regression guard.
      ProofPreLockRateLimit.ensure_table()
      SelfCheckRateLimit.ensure_table()

      pre_lock_tid = :ets.whereis(:wallop_proof_pre_lock_rate_limit)
      self_check_tid = :ets.whereis(:wallop_self_check_rate_limit)

      refute pre_lock_tid == :undefined
      refute self_check_tid == :undefined
      refute pre_lock_tid == self_check_tid
    end

    test "exhausting pre-lock bucket does not deplete self-check bucket", %{conn: conn} do
      # Cross-bucket isolation under load. The two plugs share neither
      # table nor key — exhausting one must not affect the other.
      ProofPreLockRateLimit.ensure_table()
      SelfCheckRateLimit.ensure_table()

      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      ip = "9.9.9.9"

      # Exhaust the pre-lock bucket for this IP.
      for _ <- 1..ProofPreLockRateLimit.max_attempts() do
        :ok = ProofPreLockRateLimit.check_rate(ip)
      end

      assert ProofPreLockRateLimit.check_rate(ip) == :rate_limited

      # Self-check bucket for the SAME IP must still serve.
      assert SelfCheckRateLimit.check_rate(ip) == :ok

      # And the controller plug for self-check, with an entry_id, must
      # still pass on this draw (using the same IP).
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

      # Even at high request volume, an unknown id stays at status_for/1
      # = nil and the plug does nothing. We deliberately do NOT throttle
      # not-found, because doing so would conflate "draw doesn't exist"
      # with "draw is :open and you've burned your quota" — turning the
      # rate limiter into an oracle.
      for _ <- 1..(ProofPreLockRateLimit.max_attempts() + 50) do
        result = ProofPreLockRateLimit.call(conn, [])
        refute result.halted
      end
    end
  end
end
