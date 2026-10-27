defmodule WallopCore.Resources.DrawEntropyTest do
  use WallopCore.DataCase, async: false

  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  defp with_prod_env(fun) do
    original = Application.get_env(:wallop_core, :env)
    Application.put_env(:wallop_core, :env, :prod)

    try do
      fun.()
    after
      Application.put_env(:wallop_core, :env, original)
    end
  end

  alias Ecto.Adapters.SQL
  alias WallopCore.Entropy.DrandClient
  alias WallopCore.Weather.{Schedule, Stations}

  describe "create with entropy declarations" do
    test "sets status to awaiting_entropy" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.status == :awaiting_entropy
    end

    test "declares drand round in the future" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.drand_round != nil
      assert draw.drand_round > 0
      assert draw.drand_chain == DrandClient.quicknet_chain_hash()
    end

    test "declares the observation hour that follows from the round" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.weather_time ==
               Schedule.weather_time_for_round(draw.drand_round)

      assert DateTime.compare(draw.weather_time, DateTime.utc_now()) == :gt
    end

    test "declares Middle Wallop's station" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.weather_station == Stations.primary().id
    end

    test "rejects invalid callback_url (HTTP) in prod" do
      api_key = create_api_key()

      with_prod_env(fn ->
        assert_raise Ash.Error.Invalid, fn ->
          create_draw(api_key, %{callback_url: "http://example.com/hook"})
        end
      end)
    end

    test "accepts valid HTTPS callback_url" do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{callback_url: "https://example.com/hook"})

      assert draw.callback_url == "https://example.com/hook"
    end

    test "schedules its execution job" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      jobs = all_enqueued(worker: WallopCore.Entropy.ObservationDrawWorker)
      job = Enum.find(jobs, fn j -> j.args["draw_id"] == draw.id end)
      assert job != nil
      assert job.scheduled_at != nil
    end
  end

  describe "caller-seed blocked when entropy declared" do
    test "DB trigger blocks caller-seed when drand_round is set" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert_raise Postgrex.Error, ~r/Cannot use caller-provided seed/, fn ->
        SQL.query!(
          WallopCore.Repo,
          "UPDATE draws SET seed_source = 'caller', seed = $2 WHERE id = $1",
          [Ecto.UUID.dump!(draw.id), test_seed()]
        )
      end
    end
  end
end
