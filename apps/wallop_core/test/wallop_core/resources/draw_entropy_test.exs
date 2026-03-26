defmodule WallopCore.Resources.DrawEntropyTest do
  use WallopCore.DataCase, async: false

  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias Ecto.Adapters.SQL
  alias WallopCore.Entropy.DrandClient

  describe "create with entropy declarations" do
    test "sets status to awaiting_entropy" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert draw.status == :awaiting_entropy
    end

    test "declares drand round in the future" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert draw.drand_round != nil
      assert draw.drand_round > 0
      assert draw.drand_chain == DrandClient.quicknet_chain_hash()
    end

    test "declares weather_time as ~10 minutes from now" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert draw.weather_time != nil
      # weather_time should be ~10 minutes from now, not next whole hour
      diff = DateTime.diff(draw.weather_time, DateTime.utc_now(), :second)
      assert diff > 500 and diff < 700, "Expected weather_time ~10min from now, got #{diff}s"
    end

    test "declares weather_station as middle-wallop" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert draw.weather_station == "middle-wallop"
    end

    test "rejects invalid callback_url (HTTP)" do
      api_key = create_api_key()

      assert_raise Ash.Error.Invalid, fn ->
        create_draw(api_key, %{entropy: true, callback_url: "http://example.com/hook"})
      end
    end

    test "accepts valid HTTPS callback_url" do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{entropy: true, callback_url: "https://example.com/hook"})

      assert draw.callback_url == "https://example.com/hook"
    end

    test "schedules an Oban EntropyWorker job" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{entropy: true})

      assert [job] = all_enqueued(worker: WallopCore.Entropy.EntropyWorker)
      assert job.args["draw_id"] == draw.id
      assert job.scheduled_at != nil
    end

    test "create_manual leaves draw in locked state" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{})

      assert draw.status == :locked
      assert draw.drand_round == nil
      assert draw.drand_chain == nil
      assert draw.weather_station == nil
      assert draw.weather_time == nil
    end
  end

  describe "caller-seed blocked when entropy declared" do
    test "execute with seed succeeds when no entropy sources declared" do
      api_key = create_api_key()
      draw = create_draw(api_key)
      assert draw.drand_round == nil

      executed = execute_draw(draw, test_seed(), api_key)

      assert executed.status == :completed
    end

    test "execute with seed fails when drand_round is set (Ash validation)" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      # Manually set drand_round to simulate entropy declaration.
      # Transition locked -> awaiting_entropy is valid per the DB trigger.
      SQL.query!(
        WallopCore.Repo,
        "UPDATE draws SET drand_round = 12345, status = 'awaiting_entropy' WHERE id = $1",
        [Ecto.UUID.dump!(draw.id)]
      )

      # Reload the draw so changeset.data reflects the current DB state.
      draw_with_entropy =
        Ash.get!(WallopCore.Resources.Draw, draw.id,
          domain: WallopCore.Domain,
          actor: api_key
        )

      # Attempting to execute with caller seed must fail at the Ash layer.
      assert_raise Ash.Error.Invalid, ~r/cannot use caller-provided seed/, fn ->
        execute_draw(draw_with_entropy, test_seed(), api_key)
      end
    end

    test "DB trigger also blocks caller-seed when drand_round is set" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      # Set drand_round and transition to awaiting_entropy via raw SQL.
      SQL.query!(
        WallopCore.Repo,
        "UPDATE draws SET drand_round = 12345, status = 'awaiting_entropy' WHERE id = $1",
        [Ecto.UUID.dump!(draw.id)]
      )

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
