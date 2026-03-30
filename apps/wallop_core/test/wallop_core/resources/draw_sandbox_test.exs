defmodule WallopCore.Resources.DrawSandboxTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Entropy.EntropyWorker
  alias WallopCore.Resources.Draw.Changes.ExecuteSandbox

  describe "execute_sandbox action" do
    test "executes an awaiting_entropy draw with the sandbox seed" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert draw.status == :awaiting_entropy

      executed =
        draw
        |> Ash.Changeset.for_update(:execute_sandbox, %{}, actor: api_key)
        |> Ash.update!()

      assert executed.status == :completed
      assert executed.seed == ExecuteSandbox.sandbox_seed_hex()
      assert executed.seed_source == :sandbox
      assert is_list(executed.results)
      assert length(executed.results) == 2
      assert executed.executed_at != nil
    end

    test "sandbox seed is deterministic — same entries always produce same results" do
      api_key = create_api_key()

      draw_a = create_draw(api_key)
      draw_b = create_draw(api_key)

      executed_a =
        draw_a
        |> Ash.Changeset.for_update(:execute_sandbox, %{}, actor: api_key)
        |> Ash.update!()

      executed_b =
        draw_b
        |> Ash.Changeset.for_update(:execute_sandbox, %{}, actor: api_key)
        |> Ash.update!()

      assert executed_a.results == executed_b.results
      assert executed_a.seed == executed_b.seed
    end

    test "uses the published SHA-256('wallop-sandbox') seed" do
      expected = :crypto.hash(:sha256, "wallop-sandbox") |> Base.encode16(case: :lower)
      assert ExecuteSandbox.sandbox_seed_hex() == expected
    end

    test "sets seed_source to :sandbox" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      executed =
        draw
        |> Ash.Changeset.for_update(:execute_sandbox, %{}, actor: api_key)
        |> Ash.update!()

      assert executed.seed_source == :sandbox
    end

    test "cannot sandbox-execute another key's draw" do
      api_key_a = create_api_key("key-a")
      api_key_b = create_api_key("key-b")
      draw = create_draw(api_key_a)

      assert_raise Ash.Error.Forbidden, fn ->
        draw
        |> Ash.Changeset.for_update(:execute_sandbox, %{}, actor: api_key_b)
        |> Ash.update!()
      end
    end

    test "cannot sandbox-execute an already-completed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      executed =
        draw
        |> Ash.Changeset.for_update(:execute_sandbox, %{}, actor: api_key)
        |> Ash.update!()

      assert_raise Ash.Error.Forbidden, fn ->
        executed
        |> Ash.Changeset.for_update(:execute_sandbox, %{}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "entropy worker no-ops on sandbox-completed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      # Execute via sandbox
      _executed =
        draw
        |> Ash.Changeset.for_update(:execute_sandbox, %{}, actor: api_key)
        |> Ash.update!()

      # Simulate the entropy worker firing — should no-op
      assert :ok =
               EntropyWorker.perform(%Oban.Job{
                 args: %{"draw_id" => draw.id}
               })
    end
  end

  describe "policy lockdown" do
    test "transition_to_pending is forbidden for authorized callers" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert_raise Ash.Error.Forbidden, fn ->
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "execute_with_entropy is forbidden for authorized callers" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert_raise Ash.Error.Forbidden, fn ->
        draw
        |> Ash.Changeset.for_update(
          :execute_with_entropy,
          %{
            drand_randomness: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            drand_signature: "fake",
            drand_response: "{}",
            weather_value: "12.3",
            weather_raw: "{}",
            weather_observation_time: DateTime.add(draw.inserted_at, 1, :second)
          },
          actor: api_key
        )
        |> Ash.update!()
      end
    end

    test "mark_failed is forbidden for authorized callers" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      assert_raise Ash.Error.Forbidden, fn ->
        draw
        |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "test"}, actor: api_key)
        |> Ash.update!()
      end
    end

    test "internal actions still work with authorize?: false" do
      api_key = create_api_key()
      draw = create_draw(api_key)

      # transition_to_pending should work internally
      updated =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      assert updated.status == :pending_entropy
    end
  end
end
