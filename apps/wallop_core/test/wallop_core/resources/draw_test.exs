defmodule WallopCore.Resources.DrawTest do
  use WallopCore.DataCase, async: true

  import WallopCore.TestHelpers

  alias WallopCore.Protocol

  describe "create" do
    test "creates a draw with computed entry_hash and entry_canonical" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.status == :awaiting_entropy
      assert draw.api_key_id == api_key.id
      assert draw.winner_count == 2
      assert is_binary(draw.entry_hash)
      assert String.match?(draw.entry_hash, ~r/^[0-9a-f]{64}$/)
      assert is_binary(draw.entry_canonical)
      assert is_nil(draw.seed)
      assert is_nil(draw.results)
      assert is_nil(draw.executed_at)
    end

    test "rejects empty entries" do
      api_key = create_api_key()

      assert_raise Ash.Error.Invalid, fn ->
        create_draw(api_key, %{entries: [], winner_count: 1})
      end
    end
  end

  describe "execute" do
    test "executes a draw and sets completed state" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      executed = execute_draw(draw, test_seed(), api_key)

      assert executed.status == :completed
      assert executed.seed_source == :entropy
      assert is_binary(executed.seed)
      assert is_list(executed.results)
      assert length(executed.results) == 2
      assert executed.executed_at != nil
    end

    test "cannot execute an already-completed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      executed = execute_draw(draw, test_seed(), api_key)

      assert_raise Ash.Error.Unknown, fn ->
        execute_draw(executed, test_seed(), api_key)
      end
    end

    test "cannot read another key's draw" do
      api_key_a = create_api_key("key-a")
      api_key_b = create_api_key("key-b")
      draw = create_draw(api_key_a)

      assert_raise Ash.Error.Invalid, fn ->
        Ash.get!(WallopCore.Resources.Draw, draw.id, actor: api_key_b)
      end
    end
  end

  describe "protocol integration" do
    test "locked draw produces a valid entry_hash computable from loaded entries" do
      api_key = create_api_key()

      entries = [
        %{"ref" => "ticket-47", "weight" => 1},
        %{"ref" => "ticket-48", "weight" => 1},
        %{"ref" => "ticket-49", "weight" => 1}
      ]

      draw = create_draw(api_key, %{entries: entries, winner_count: 2})

      loaded = WallopCore.Entries.load_for_draw(draw.id)
      {recomputed, _jcs} = Protocol.entry_hash({draw.id, loaded})

      assert draw.entry_hash == recomputed
      assert String.match?(draw.entry_hash, ~r/\A[0-9a-f]{64}\z/)
    end
  end
end
