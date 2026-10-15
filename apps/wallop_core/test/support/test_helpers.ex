defmodule WallopCore.TestHelpers do
  @moduledoc """
  Convenience functions for creating test data.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entries
  alias WallopCore.Protocol
  alias WallopCore.Repo
  alias WallopCore.Resources.{Draw, Operator, OperatorReceipt, OperatorSigningKey}
  alias WallopCore.Vault
  alias WallopCore.Weather.{Schedule, Stations}

  @doc """
  Creates an active API key and returns the struct (actor for Ash calls).

  Accepts optional `:name` and `:rate_limit_per_minute`.
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
      |> Map.take([:name, :rate_limit_per_minute])
      |> Map.put(:operator_id, operator.id)

    WallopCore.Resources.ApiKey
    |> Ash.Changeset.for_create(:create, create_attrs)
    |> Ash.create!(authorize?: false)
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
      %{"weight" => 1},
      %{"weight" => 1},
      %{"weight" => 1}
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
      |> Ash.Changeset.for_update(
        :add_entries,
        %{entries: entries, client_ref: Ash.UUID.generate()},
        actor: api_key
      )
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
        valid_from: DateTime.add(DateTime.utc_now(), -30, :second)
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
        valid_from: DateTime.add(DateTime.utc_now(), -30, :second)
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

  @doc "An operator on the observation weather protocol, and an API key for it."
  def create_v6_operator do
    operator = create_operator()

    {:ok, operator} =
      operator
      |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :observation})
      |> Ash.update(authorize?: false)

    {operator, create_api_key_for_operator(operator)}
  end

  @doc "An open draw with `n` weight-1 entries."
  def open_draw_with_entries(api_key, n \\ 3) do
    Draw
    |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
    |> Ash.create!()
    |> Ash.Changeset.for_update(
      :add_entries,
      %{entries: List.duplicate(%{"weight" => 1}, n), client_ref: Ash.UUID.generate()},
      actor: api_key
    )
    |> Ash.update!()
  end

  @doc """
  True when the database refuses `sql`. Runs it in a savepoint so the test
  transaction survives a refusal.
  """
  def db_refused?(sql, params) do
    Repo.transaction(fn -> Repo.query!(sql, params) end)
    false
  rescue
    Postgrex.Error -> true
  end

  @doc """
  Puts an open draw into awaiting_entropy as a v6 draw, and stores a signed
  lock v6 receipt for it.

  The draw row gets `weather_time` and `drand_round` as given. Test-only: it
  turns triggers off for that one UPDATE, so tests can place the fetch window
  around the current time (a real lock can't, because it must happen 46
  minutes before weather_time).

  The receipt is a real one: it goes through `Protocol.build_v6_lock_payload/1`
  with the round's own observation hour, `Schedule.weather_time_for_round/1`,
  and a `locked_at` 47 minutes before that hour, and it is inserted with the
  triggers on. So `weather_time` may differ from the signed hour, but
  `drand_round` is the signed round.

  Options: `:entropy_composition` (default: the Land Observations tag).
  Returns the draw with `expected_result_at` loaded.
  """
  def put_v6_awaiting!(draw, %DateTime{} = weather_time, drand_round, opts \\ [])
      when is_integer(drand_round) do
    tag =
      Keyword.get(opts, :entropy_composition, Protocol.landobs_entropy_composition())

    entries = Entries.load_for_draw(draw.id)
    {hash, canonical} = Protocol.entry_hash({draw.id, entries})
    chain = Quicknet.chain_hash()

    Repo.query!("SET session_replication_role = replica")

    try do
      Repo.query!(
        """
        UPDATE draws SET status = 'awaiting_entropy', lock_schema_version = '6',
          entropy_composition = $7, entry_hash = $2, entry_canonical = $3, drand_chain = $4,
          drand_round = $5, weather_station = $8, weather_time = $6
        WHERE id = $1
        """,
        [
          Ecto.UUID.dump!(draw.id),
          hash,
          canonical,
          chain,
          drand_round,
          DateTime.to_naive(weather_time),
          tag,
          Stations.primary().id
        ]
      )
    after
      Repo.query!("RESET session_replication_role")
    end

    insert_v6_lock_receipt!(draw, hash, tag, drand_round)
    Ash.get!(Draw, draw.id, authorize?: false, load: [:expected_result_at])
  end

  @doc """
  The signed lock v6 receipt `put_v6_awaiting!/4` stores. `locked_at` is 47
  minutes before the round's observation hour; it is both the signed value
  and the receipt's `locked_at` column.
  """
  def insert_v6_lock_receipt!(draw, entry_hash, entropy_composition, drand_round) do
    require Ash.Query

    operator_id = draw.operator_id

    key =
      OperatorSigningKey
      |> Ash.Query.filter(operator_id == ^operator_id)
      |> Ash.read_one!(authorize?: false)

    {:ok, private} = Vault.decrypt(key.private_key)
    operator = Ash.get!(Operator, operator_id, authorize?: false)
    signed_wt = Schedule.weather_time_for_round(drand_round)
    locked_at = DateTime.add(signed_wt, -47 * 60, :second)

    payload =
      Protocol.build_v6_lock_payload(%{
        entropy_composition: entropy_composition,
        operator_id: operator.id,
        operator_slug: to_string(operator.slug),
        sequence: draw.operator_sequence,
        draw_id: draw.id,
        commitment_hash: entry_hash,
        entry_hash: entry_hash,
        locked_at: locked_at,
        signing_key_id: key.key_id,
        winner_count: draw.winner_count,
        drand_chain: Quicknet.chain_hash(),
        drand_round: drand_round,
        weather_station: Stations.primary().id,
        weather_time: signed_wt,
        wallop_core_version: to_string(Application.spec(:wallop_core, :vsn)),
        fair_pick_version: to_string(Application.spec(:fair_pick, :vsn))
      })

    OperatorReceipt
    |> Ash.Changeset.for_create(:create, %{
      operator_id: operator.id,
      draw_id: draw.id,
      sequence: draw.operator_sequence,
      commitment_hash: entry_hash,
      entry_hash: entry_hash,
      locked_at: locked_at,
      signing_key_id: key.key_id,
      payload_jcs: payload,
      signature: Protocol.sign_receipt(payload, private)
    })
    |> Ash.create!(authorize?: false)
  end
end
