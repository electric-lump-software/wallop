defmodule WallopWeb.IpAuthLimitTest do
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers

  alias Ecto.Adapters.SQL
  alias WallopWeb.IpAuthLimit
  alias WallopWeb.RateLimitHelpers

  defp api_conn(ip, bearer) do
    %{build_conn() | remote_ip: ip}
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> put_req_header("accept", "application/vnd.api+json")
  end

  defp bad_key, do: "wallop_" <> String.duplicate("Z", 43)
  defp status(ip, bearer), do: api_conn(ip, bearer) |> get("/api/v1/health") |> Map.get(:status)

  defp exhaust(ip), do: for(_ <- 1..IpAuthLimit.max_failures(), do: status(ip, bad_key()))

  # Same prefix as `raw`, wrong secret: finds the key, fails verification.
  defp wrong_secret_for("wallop_" <> <<prefix::binary-size(8), _::binary>>),
    do: "wallop_" <> prefix <> String.duplicate("Z", 35)

  defp clear_digest(api_key) do
    SQL.query!(
      WallopCore.Repo,
      "UPDATE api_keys SET key_digest = NULL WHERE id = $1",
      [Ecto.UUID.dump!(api_key.id)]
    )
  end

  test "valid requests don't use up the per-IP budget" do
    raw = create_api_key().__metadata__.raw_key
    for _ <- 1..40, do: assert(status({10, 1, 0, 1}, raw) == 200)
  end

  test "failed authentications get 401, then 429 with Retry-After and a JSON:API body" do
    RateLimitHelpers.await_fresh_window()
    ip = {10, 1, 0, 3}
    assert Enum.all?(exhaust(ip), &(&1 == 401))

    conn = api_conn(ip, bad_key()) |> get("/api/v1/health")
    assert conn.status == 429
    [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..60

    assert %{"errors" => [%{"status" => "429", "code" => "ip_rate_limit_exceeded"}]} =
             Jason.decode!(conn.resp_body)
  end

  test "every per-IP 429 emits telemetry without the address" do
    RateLimitHelpers.await_fresh_window()
    ip = {10, 1, 0, 9}
    exhaust(ip)

    ref = make_ref()
    me = self()
    handler = "ip-auth-denied-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:wallop_web, :ip_auth_limit, :denied],
      fn _event, measurements, metadata, _ -> send(me, {ref, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert status(ip, bad_key()) == 429
    assert_receive {^ref, %{count: 1}, metadata}
    assert metadata == %{}
  end

  test "a burst of concurrent bad keys is still capped" do
    RateLimitHelpers.await_fresh_window()
    ip = {10, 1, 0, 6}
    n = IpAuthLimit.max_failures() + 10

    statuses =
      1..n
      |> Task.async_stream(fn _ -> status(ip, bad_key()) end, max_concurrency: n)
      |> Enum.map(fn {:ok, s} -> s end)

    assert Enum.count(statuses, &(&1 == 401)) == IpAuthLimit.max_failures()
    assert Enum.count(statuses, &(&1 == 429)) == 10
  end

  test "an IP over the failure limit still gets 200 for a valid key" do
    RateLimitHelpers.await_fresh_window()
    ip = {10, 1, 0, 2}
    raw = create_api_key().__metadata__.raw_key
    exhaust(ip)
    assert status(ip, bad_key()) == 429
    assert status(ip, raw) == 200
  end

  test "an IP over the limit gets 429 before bcrypt for a key with no digest yet" do
    RateLimitHelpers.await_fresh_window()
    ip = {10, 1, 0, 7}
    api_key = create_api_key()
    clear_digest(api_key)

    exhaust(ip)
    assert status(ip, api_key.__metadata__.raw_key) == 429
    assert status({10, 1, 0, 8}, api_key.__metadata__.raw_key) == 200
  end

  test "bcrypt-path failures are counted once each: 401 exactly max_failures times, then 429" do
    RateLimitHelpers.await_fresh_window()
    ip = {10, 1, 0, 10}
    api_key = create_api_key()
    clear_digest(api_key)
    wrong = wrong_secret_for(api_key.__metadata__.raw_key)

    statuses = for _ <- 1..IpAuthLimit.max_failures(), do: status(ip, wrong)
    assert Enum.all?(statuses, &(&1 == 401))
    assert status(ip, wrong) == 429
  end

  test "another IP is unaffected" do
    RateLimitHelpers.await_fresh_window()
    exhaust({10, 1, 0, 4})
    assert status({10, 1, 0, 5}, bad_key()) == 401
  end

  test "IPv6 addresses in one /64 share a budget" do
    RateLimitHelpers.await_fresh_window()
    exhaust({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1})
    assert status({0x2001, 0xDB8, 1, 2, 0xFFFF, 0, 0, 9}, bad_key()) == 429
    assert status({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1}, bad_key()) == 401
  end
end
