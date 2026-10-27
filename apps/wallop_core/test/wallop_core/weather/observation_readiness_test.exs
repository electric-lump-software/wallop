defmodule WallopCore.Weather.ObservationReadinessTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.DbClock
  alias WallopCore.Repo
  alias WallopCore.Resources.ObservationReadiness, as: Record
  alias WallopCore.Weather.{ObservationReadiness, ObservationReadinessWorker}

  @key "SENTINEL-READY-KEY-5a4b"

  setup do
    previous = Application.get_env(:wallop_core, :met_office_obs_api_key)
    Application.put_env(:wallop_core, :met_office_obs_api_key, @key)
    put_observation_readiness!(nil)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wallop_core, :met_office_obs_api_key, previous),
        else: Application.delete_env(:wallop_core, :met_office_obs_api_key)
    end)
  end

  defp rows do
    %{rows: rows} = Repo.query!("SELECT * FROM observation_readiness")
    rows
  end

  defp record, do: Ash.read_one!(Record, authorize?: false)

  @weather_node [queues: [entropy: 10, weather: 5, default: 5]]

  describe "who writes it" do
    test "a node running the weather queue with a usable key records ready" do
      assert ObservationReadiness.publish(@weather_node) == :recorded
      assert %{ready: true} = record()
      assert ObservationReadiness.ready?()
    end

    test "a node running the weather queue without a usable key records not ready" do
      for key <- [nil, "", "has space"] do
        if key,
          do: Application.put_env(:wallop_core, :met_office_obs_api_key, key),
          else: Application.delete_env(:wallop_core, :met_office_obs_api_key)

        assert ObservationReadiness.publish(@weather_node) == :recorded
        assert %{ready: false} = record()
        refute ObservationReadiness.ready?()
      end
    end

    test "a node without the weather queue never writes it, key or no key" do
      for config <- [
            [queues: false, plugins: false],
            [queues: []],
            [queues: [entropy: 10, webhooks: 5, default: 5]],
            [prefix: "oban_app", queues: [default: 5]],
            []
          ] do
        assert ObservationReadiness.publish(config) == :skipped
        assert rows() == []

        Application.delete_env(:wallop_core, :met_office_obs_api_key)
        assert ObservationReadiness.publish(config) == :skipped
        assert rows() == []
        Application.put_env(:wallop_core, :met_office_obs_api_key, @key)
      end
    end

    test "an insert-only node leaves another node's record alone" do
      assert ObservationReadiness.publish(@weather_node) == :recorded
      before = record()

      assert ObservationReadiness.publish(queues: false) == :skipped
      assert record() == before
    end

    test "the boot write is skipped while Oban is in a testing mode" do
      assert Keyword.get(Application.get_env(:wallop_core, Oban), :testing) == :manual
      assert ObservationReadiness.publish_at_boot() == :skipped
      assert rows() == []
    end

    test "the boot write is a one-shot child after Oban in the application" do
      source = File.read!(Path.expand("../../../lib/wallop_core/application.ex", __DIR__))
      [_, after_oban] = String.split(source, "{Oban, Application.fetch_env!(:wallop_core, Oban)}")

      assert after_oban =~
               ~r/\A,\s*(#[^\n]*\n\s*)*Supervisor\.child_spec\(\{Task, &ObservationReadiness\.publish_at_boot\/0\}/
    end
  end

  describe "the scheduled check" do
    test "runs on the weather queue, so only the fetching node runs it" do
      assert ObservationReadinessWorker.new(%{}).changes.queue == "weather"
    end

    test "is in core's cron every 10 minutes" do
      crontab =
        Application.get_env(:wallop_core, Oban)
        |> Keyword.get(:plugins, [])
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab)
          _ -> nil
        end)

      assert {"*/10 * * * *", ObservationReadinessWorker} in crontab
    end

    test "records readiness when it runs, and refreshes checked_at" do
      put_observation_readiness!(true, 25 * 60)
      old = record().checked_at

      assert :ok = perform_job(ObservationReadinessWorker, %{})
      assert %{ready: true, checked_at: new} = record()
      assert DateTime.compare(new, old) == :gt
      assert abs(DateTime.diff(new, DbClock.now(), :second)) <= 5
    end
  end

  describe "what it holds" do
    test "only ready and checked_at, never the key or anything derived from it" do
      assert ObservationReadiness.publish(@weather_node) == :recorded

      %{columns: columns, rows: [row]} = Repo.query!("SELECT * FROM observation_readiness")
      assert Enum.sort(columns) == ["checked_at", "ready", "singleton"]
      refute inspect(row) =~ "SENTINEL"
      refute inspect(row) =~ Base.encode16(:crypto.hash(:sha256, @key), case: :lower)
    end

    test "one row only" do
      assert ObservationReadiness.publish(@weather_node) == :recorded
      assert ObservationReadiness.publish(@weather_node) == :recorded
      assert length(rows()) == 1

      assert db_refused?(
               "INSERT INTO observation_readiness (singleton, ready, checked_at) VALUES (false, true, now())",
               []
             )
    end

    test "checked_at is the database clock's" do
      assert ObservationReadiness.publish(@weather_node) == :recorded
      assert abs(DateTime.diff(record().checked_at, DbClock.now(), :second)) <= 5
    end

    test "staleness is measured on the database clock: 30 minutes" do
      assert ObservationReadiness.stale_after_minutes() == 30
      put_observation_readiness!(true, 29 * 60)
      assert ObservationReadiness.ready?()
      put_observation_readiness!(true, 31 * 60)
      refute ObservationReadiness.ready?()
      put_observation_readiness!(false, 0)
      refute ObservationReadiness.ready?()
      put_observation_readiness!(nil)
      refute ObservationReadiness.ready?()
    end

    test "actors can't read or write it" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Record
               |> Ash.Changeset.for_create(:record, %{ready: true})
               |> Ash.create(actor: %{id: "someone"})

      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Record, actor: %{id: "someone"})
      assert rows() == []
    end
  end
end
