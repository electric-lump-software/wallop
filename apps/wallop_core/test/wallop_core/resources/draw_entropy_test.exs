defmodule WallopCore.Resources.DrawEntropyTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias Ecto.Adapters.SQL

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
