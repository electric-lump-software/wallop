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

    # All API keys must have an operator (draws require it for the proof protocol).
    # Auto-create one if not provided.
    operator = Map.get_lazy(attrs, :operator, fn -> create_operator() end)

    create_attrs =
      attrs
      |> Map.take([:name, :tier, :monthly_draw_limit, :count_reset_at])
      |> Map.put(:operator_id, operator.id)

    api_key =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, create_attrs)
      |> Ash.create!(authorize?: false)

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
      %{"ref" => "ticket-47", "weight" => 1},
      %{"ref" => "ticket-48", "weight" => 1},
      %{"ref" => "ticket-49", "weight" => 1}
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
    ensure_infrastructure_key()

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

  @doc """
  Ensures at least one infrastructure signing key exists.
  Creates one if none found. Idempotent.
  """
  def ensure_infrastructure_key do
    case WallopCore.Resources.InfrastructureSigningKey
         |> Ash.Query.limit(1)
         |> Ash.read!(authorize?: false) do
      [_key] -> :ok
      [] -> create_infrastructure_key() && :ok
    end
  end

  @doc "Returns a deterministic drand randomness hex value for tests."
  def test_drand_randomness do
    "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
  end

  @doc """
  Creates an Operator with a single Ed25519 signing key, returning the
  operator struct. Useful for tests that exercise the operator/receipt path.
  """
  def create_operator(slug \\ nil, name \\ "Test Operator") do
    slug = slug || "op-#{:rand.uniform(1_000_000)}"

    {:ok, operator} =
      WallopCore.Resources.Operator
      |> Ash.Changeset.for_create(:create, %{slug: slug, name: name})
      |> Ash.create(authorize?: false)

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = WallopCore.Protocol.key_id(public_key)
    {:ok, encrypted} = WallopCore.Vault.encrypt(private_key)

    {:ok, _key} =
      WallopCore.Resources.OperatorSigningKey
      |> Ash.Changeset.for_create(:create, %{
        operator_id: operator.id,
        key_id: key_id,
        public_key: public_key,
        private_key: encrypted,
        valid_from: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Ash.create(authorize?: false)

    operator
  end

  @doc """
  Creates (or ensures) a wallop infrastructure signing key for execution
  receipts. Returns the InfrastructureSigningKey struct.
  """
  def create_infrastructure_key do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = WallopCore.Protocol.key_id(public_key)
    {:ok, encrypted} = WallopCore.Vault.encrypt(private_key)

    {:ok, key} =
      WallopCore.Resources.InfrastructureSigningKey
      |> Ash.Changeset.for_create(:create, %{
        key_id: key_id,
        public_key: public_key,
        private_key: encrypted,
        valid_from: DateTime.add(DateTime.utc_now(), -60, :second)
      })
      |> Ash.create(authorize?: false)

    key
  end

  @doc "Creates an api_key bound to the given operator."
  def create_api_key_for_operator(operator, name \\ "op-key") do
    WallopCore.Resources.ApiKey
    |> Ash.Changeset.for_create(:create, %{name: name, operator_id: operator.id})
    |> Ash.create!(authorize?: false)
  end
end
