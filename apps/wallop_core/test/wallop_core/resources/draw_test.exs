defmodule WallopCore.Resources.DrawTest do
  use WallopCore.DataCase, async: true

  import WallopCore.TestHelpers

  alias WallopCore.Protocol

  describe "create" do
    test "creates a locked draw with computed entry_hash and entry_canonical" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.status == :locked
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
    test "executes a locked draw and sets completed state" do
      api_key = create_api_key()
      draw = create_draw(api_key)
      seed = test_seed()

      executed = execute_draw(draw, seed, api_key)

      assert executed.status == :completed
      assert executed.seed == seed
      assert executed.seed_source == :caller
      assert is_list(executed.results)
      assert length(executed.results) == 2
      assert executed.executed_at != nil
    end

    test "results are deterministic — same entries and seed produce same results" do
      api_key = create_api_key()
      seed = test_seed()

      draw_a = create_draw(api_key)
      draw_b = create_draw(api_key)

      executed_a = execute_draw(draw_a, seed, api_key)
      executed_b = execute_draw(draw_b, seed, api_key)

      assert executed_a.results == executed_b.results
    end

    test "cannot execute an already-completed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)
      seed = test_seed()

      executed = execute_draw(draw, seed, api_key)

      assert_raise Ash.Error.Forbidden, fn ->
        execute_draw(executed, seed, api_key)
      end
    end

    test "rejects invalid seed format" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert_raise Ash.Error.Invalid, fn ->
        execute_draw(draw, "not-a-hex-string", api_key)
      end

      assert_raise Ash.Error.Invalid, fn ->
        execute_draw(draw, "abcd1234", api_key)
      end
    end

    test "cannot execute another key's draw" do
      api_key_a = create_api_key("key-a")
      api_key_b = create_api_key("key-b")
      draw = create_draw(api_key_a)
      seed = test_seed()

      assert_raise Ash.Error.Forbidden, fn ->
        execute_draw(draw, seed, api_key_b)
      end
    end
  end

  describe "read" do
    test "cannot read another key's draw" do
      api_key_a = create_api_key("key-a")
      api_key_b = create_api_key("key-b")
      draw = create_draw(api_key_a)

      assert_raise Ash.Error.Invalid, fn ->
        Ash.get!(WallopCore.Resources.Draw, draw.id, actor: api_key_b)
      end
    end
  end

  describe "protocol integration (spec vector P-3)" do
    test "create draw with P-3 entries, compute seed via Protocol, execute, verify results" do
      api_key = create_api_key()

      entries = [
        %{"id" => "ticket-47", "weight" => 1},
        %{"id" => "ticket-48", "weight" => 1},
        %{"id" => "ticket-49", "weight" => 1}
      ]

      draw = create_draw(api_key, %{entries: entries, winner_count: 2})

      # Verify entry hash matches P-1 vector
      assert draw.entry_hash ==
               "6056fbb6c98a0f04404adb013192d284bfec98975e2a7975395c3bcd4ad59577"

      # Compute seed using Protocol (P-2 inputs)
      drand = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      weather = "1013"
      {seed_bytes, _seed_json} = Protocol.compute_seed(draw.entry_hash, drand, weather)
      seed_hex = Base.encode16(seed_bytes, case: :lower)

      assert seed_hex == "ced93f50d73a619701e9e865eb03fb4540a7232a588c707f85754aa41e3fb037"

      # Execute the draw
      executed = execute_draw(draw, seed_hex, api_key)

      # Verify results match P-3 frozen vector
      assert executed.results == [
               %{"position" => 1, "entry_id" => "ticket-48"},
               %{"position" => 2, "entry_id" => "ticket-47"}
             ]
    end
  end
end
