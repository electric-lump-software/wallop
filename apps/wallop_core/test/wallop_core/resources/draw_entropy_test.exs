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

    test "declares weather_time as ~10 minutes from now" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.weather_time != nil
      # weather_time should be ~10 minutes from now, not next whole hour
      diff = DateTime.diff(draw.weather_time, DateTime.utc_now(), :second)
      assert diff > 500 and diff < 700, "Expected weather_time ~10min from now, got #{diff}s"
    end

    test "declares weather_station as middle-wallop" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.weather_station == "middle-wallop"
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

    test "schedules an Oban EntropyWorker job" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      jobs = all_enqueued(worker: WallopCore.Entropy.EntropyWorker)
      job = Enum.find(jobs, fn j -> j.args["draw_id"] == draw.id end)
      assert job != nil
      assert job.scheduled_at != nil
    end
  end

  describe "caller-seed blocked when entropy declared" do
    test "execute with caller seed fails when entropy is declared (Ash validation)" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.drand_round != nil

      # The :execute action requires status == :locked, but all draws now go
      # through the entropy flow (status == :awaiting_entropy with drand_round set).
      # Even if we could reach :locked status, the NoEntropyDeclared validation
      # would reject caller-provided seeds when drand_round is set.
      #
      # Verify by calling :execute directly — it should fail because the draw
      # is not in :locked status (filter won't match).
      assert_raise Ash.Error.Invalid, ~r/cannot use caller-provided seed/, fn ->
        draw
        |> Ash.Changeset.for_update(:execute, %{seed: test_seed()}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "DB trigger blocks caller-seed when drand_round is set" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      # Attempt to set seed_source = 'caller' directly, bypassing Ash.
      # Keep status unchanged (awaiting_entropy -> awaiting_entropy is valid per trigger)
      # so that the entropy-seed check is reached.
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
