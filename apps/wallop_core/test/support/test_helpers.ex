defmodule WallopCore.TestHelpers do
  @moduledoc """
  Convenience functions for creating test data.
  """

  @doc "Creates an active API key and returns the struct (actor for Ash calls)."
  def create_api_key(name \\ "test-key") do
    WallopCore.Resources.ApiKey
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!()
  end

  @doc """
  Creates a draw with sensible defaults, using the given api_key as actor.

  By default, uses `:create_manual` (no entropy) so the draw stays in `:locked`
  status — suitable for caller-seed execute tests. Pass `entropy: true` to use
  the open draw flow (create → add_entries → lock) which produces a draw in
  `:awaiting_entropy` status.
  """
  def create_draw(api_key, attrs \\ %{}) do
    {use_entropy, params} = Map.pop(attrs, :entropy, false)
    {entries, params} = Map.pop(params, :entries, nil)
    # Strip legacy skip_entropy if present
    {_, params} = Map.pop(params, :skip_entropy)

    default_entries = [
      %{"id" => "ticket-47", "weight" => 1},
      %{"id" => "ticket-48", "weight" => 1},
      %{"id" => "ticket-49", "weight" => 1}
    ]

    entries = entries || default_entries
    winner_count = Map.get(params, :winner_count, 2)

    if use_entropy do
      # Open draw flow: create → add_entries → lock
      draw =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, Map.merge(%{winner_count: winner_count}, params),
          actor: api_key
        )
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(:add_entries, %{entries: entries}, actor: api_key)
        |> Ash.update!()

      # Lock computes hash and declares entropy
      draw
      |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
      |> Ash.update!()
    else
      # Manual flow: creates a locked draw directly (no entropy)
      WallopCore.Resources.Draw
      |> Ash.Changeset.for_create(
        :create_manual,
        Map.merge(%{entries: entries, winner_count: winner_count}, params),
        actor: api_key
      )
      |> Ash.create!()
    end
  end

  @doc "Executes a draw with the given hex seed, using the api_key as actor."
  def execute_draw(draw, seed_hex, api_key) do
    draw
    |> Ash.Changeset.for_update(:execute, %{seed: seed_hex}, actor: api_key)
    |> Ash.update!()
  end

  @doc "Returns a known 64-character hex string for deterministic test draws."
  def test_seed do
    "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  end
end
