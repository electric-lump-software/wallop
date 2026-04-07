defmodule WallopCore.TestHelpers do
  @moduledoc """
  Convenience functions for creating test data.
  """

  @doc """
  Creates an active API key and returns the struct (actor for Ash calls).

  Accepts optional tier metadata: `tier`, `monthly_draw_limit`,
  `monthly_draw_count`, `count_reset_at`.
  """
  def create_api_key(name_or_attrs \\ "test-key")

  def create_api_key(name) when is_binary(name) do
    create_api_key(%{name: name})
  end

  def create_api_key(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :name, "test-key")
    create_attrs = Map.take(attrs, [:name, :tier, :monthly_draw_limit, :count_reset_at])

    api_key =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, create_attrs)
      |> Ash.create!()

    case Map.get(attrs, :monthly_draw_count) do
      nil ->
        api_key

      count when is_integer(count) ->
        # Bump the count to the requested value via direct DB update
        WallopCore.Repo.query!(
          "UPDATE api_keys SET monthly_draw_count = $2 WHERE id = $1",
          [Ecto.UUID.dump!(api_key.id), count]
        )

        Ash.get!(WallopCore.Resources.ApiKey, api_key.id, authorize?: false)
    end
  end

  @doc """
  Creates a draw with sensible defaults, using the given api_key as actor.

  Uses the full open draw flow (create → add_entries → lock) which produces
  a draw in `:awaiting_entropy` status with entropy sources declared.
  """
  def create_draw(api_key, attrs \\ %{}) do
    {entries, params} = Map.pop(attrs, :entries, nil)
    # Strip legacy flags if present
    {_, params} = Map.pop(params, :entropy)
    {_, params} = Map.pop(params, :skip_entropy)

    default_entries = [
      %{"id" => "ticket-47", "weight" => 1},
      %{"id" => "ticket-48", "weight" => 1},
      %{"id" => "ticket-49", "weight" => 1}
    ]

    entries = entries || default_entries
    winner_count = Map.get(params, :winner_count, 2)

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
  end

  @doc """
  Executes a draw via the entropy path with a deterministic test seed.

  Transitions through awaiting_entropy → pending_entropy → completed
  using fake entropy values.
  """
  def execute_draw(draw, _seed_hex, _api_key) do
    # Transition to pending_entropy
    draw =
      draw
      |> Ash.Changeset.for_update(:transition_to_pending, %{})
      |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

    # Execute with fake entropy values
    draw
    |> Ash.Changeset.for_update(:execute_with_entropy, %{
      drand_randomness: test_drand_randomness(),
      drand_signature: "test-signature",
      drand_response: "{}",
      weather_value: "12.3",
      weather_raw: "{}",
      weather_observation_time: DateTime.add(draw.inserted_at, 1, :second)
    })
    |> Ash.update!(domain: WallopCore.Domain, authorize?: false)
  end

  @doc "Returns a known 64-character hex string for deterministic test draws."
  def test_seed do
    "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  end

  @doc "Returns a deterministic drand randomness hex value for tests."
  def test_drand_randomness do
    "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
  end
end
