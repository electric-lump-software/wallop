defmodule WallopCore.RateLimitEventsTest do
  use WallopCore.DataCase, async: true
  use Oban.Testing, repo: WallopCore.Repo

  import ExUnit.CaptureLog
  import WallopCore.TestHelpers

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias WallopCore.RateLimitEvents
  alias WallopCore.Resources.RateLimitEvent

  # The rows' window_start is the minute of each call; keep the test inside
  # one minute so it can't straddle an edge.
  defp await_fresh_minute do
    remaining = 60_000 - rem(System.system_time(:millisecond), 60_000)
    if remaining < 5_000, do: Process.sleep(remaining + 50)
  end

  test "records one row per key, kind and minute" do
    await_fresh_minute()
    key = create_api_key()
    :ok = RateLimitEvents.record(key.id, :near_limit, 60)
    :ok = RateLimitEvents.record(key.id, :near_limit, 60)
    :ok = RateLimitEvents.record(key.id, :limited, 60)

    rows = Ash.read!(RateLimitEvent, authorize?: false)
    assert Enum.count(rows, &(&1.kind == :near_limit)) == 1
    assert Enum.count(rows, &(&1.kind == :limited)) == 1
    assert Enum.all?(rows, &(&1.window_start.second == 0))
  end

  test "never raises, even for an unknown key" do
    log =
      capture_log(fn ->
        assert :ok = RateLimitEvents.record(Ash.UUID.generate(), :limited, 60)
      end)

    assert log =~ "not recorded"
  end

  test "rate_limit_per_minute is set through update_tier and bounded" do
    key = create_api_key()

    assert {:ok, %{rate_limit_per_minute: 300}} =
             key
             |> Ash.Changeset.for_update(:update_tier, %{rate_limit_per_minute: 300})
             |> Ash.update(authorize?: false)

    for bad <- [0, 6001] do
      assert {:error, _} =
               key
               |> Ash.Changeset.for_update(:update_tier, %{rate_limit_per_minute: bad})
               |> Ash.update(authorize?: false)
    end
  end

  test "rate_limit_per_minute is set through create" do
    operator = create_operator()

    key =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, %{
        name: "limited",
        operator_id: operator.id,
        rate_limit_per_minute: 120
      })
      |> Ash.create!(authorize?: false)

    assert key.rate_limit_per_minute == 120
  end

  test "events are not readable or writable by API callers" do
    key = create_api_key()
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(RateLimitEvent, actor: key)
  end

  test ":recent returns events since a time, newest first" do
    key = create_api_key()
    :ok = RateLimitEvents.record(key.id, :near_limit, 60)
    :ok = RateLimitEvents.record(key.id, :limited, 60)

    since = DateTime.add(DateTime.utc_now(), -600, :second)

    events =
      RateLimitEvent
      |> Ash.Query.for_read(:recent, %{since: since})
      |> Ash.read!(authorize?: false)

    assert Enum.map(events, & &1.kind) |> Enum.sort() == [:limited, :near_limit]
    assert Enum.all?(events, &(&1.limit_per_minute == 60))

    future = DateTime.add(DateTime.utc_now(), 600, :second)

    assert [] =
             RateLimitEvent
             |> Ash.Query.for_read(:recent, %{since: future})
             |> Ash.read!(authorize?: false)
  end

  test "prune deletes rows older than the retention period" do
    key = create_api_key()
    :ok = RateLimitEvents.record(key.id, :limited, 60)
    old_id = Ash.read!(RateLimitEvent, authorize?: false) |> hd() |> Map.fetch!(:id)

    SQL.query!(
      WallopCore.Repo,
      "UPDATE rate_limit_events SET window_start = now() - interval '31 days' WHERE id = $1",
      [Ecto.UUID.dump!(old_id)]
    )

    :ok = RateLimitEvents.record(key.id, :near_limit, 60)

    assert RateLimitEvents.prune(DateTime.utc_now()) == 1
    assert [%{kind: :near_limit}] = Ash.read!(RateLimitEvent, authorize?: false)
  end

  test "the prune worker runs prune" do
    assert :ok = perform_job(WallopCore.RateLimitEvents.PruneWorker, %{})
  end
end
