defmodule WallopCore.TestHelpers do
  @moduledoc """
  Convenience functions for creating test data.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entries
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
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

    operator =
      Map.get_lazy(attrs, :operator, fn ->
        put_observation_readiness!(true)
        create_operator()
      end)

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
  a draw in `:awaiting_entropy` status with entropy sources declared. The
  operator's protocol decides the tag (observation weather by default); the
  observation readiness record is set to ready first, as a working fetcher
  would keep it.
  """
  def create_draw(api_key, attrs \\ %{}) do
    {entries, params} = Map.pop(attrs, :entries, nil)
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

    put_observation_readiness!(true)

    draw
    |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
    |> Ash.update!()
  end

  @test_observation "141;1025;85;2432"

  @doc "The Land Observations reading `execute_draw/3` stores and completes with."
  def test_observation, do: @test_observation

  @doc """
  Completes a Land Observations draw locked by `create_draw/2` through the
  real `:execute_v6` action, in state (a): Middle Wallop's reading is used.

  A real lock commits to a round about 1.5 hours ahead, so with every
  trigger off this first moves the draw to a round three hours in the past
  and re-signs its lock receipt for that round (as `put_v6_awaiting!/4`
  does), and stores the hour's reading. Everything after that runs with the
  triggers on.
  """
  def execute_draw(draw, _seed_hex \\ nil, _api_key \\ nil) do
    ensure_infrastructure_key()

    draw
    |> pending_for_execution!()
    |> Ash.Changeset.for_update(:execute_v6, test_drand_args())
    |> Ash.update!(domain: WallopCore.Domain, authorize?: false)
  end

  @doc "The drand arguments `execute_draw/3` passes to `:execute_v6`."
  def test_drand_args do
    %{
      drand_randomness: test_drand_randomness(),
      drand_signature: test_drand_signature(),
      drand_response: "{}"
    }
  end

  @doc """
  The first half of `execute_draw/3`: moves a Land Observations draw locked
  by `create_draw/2` to a round three hours in the past (with every trigger
  off, re-signing its lock receipt for that round) and into
  `pending_entropy`, ready for `:execute_v6`. With `observation: false` no
  reading is stored, so the draw completes on drand alone (state (c)).
  """
  def pending_for_execution!(draw, opts \\ []) do
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -3 * 3600))
    wt = Schedule.weather_time_for_round(round)

    with_triggers_off(fn ->
      Repo.query!(
        """
        UPDATE draws SET drand_round = $2, weather_time = $3, freq_start = $4 WHERE id = $1
        """,
        [
          Ecto.UUID.dump!(draw.id),
          round,
          DateTime.to_naive(wt),
          DateTime.to_naive(FreqSchedule.freq_start_for_round(round))
        ]
      )

      %{rows: [[key_id, private_key]]} =
        Repo.query!(
          """
          SELECT k.key_id, k.private_key FROM operator_receipts r
          JOIN operator_signing_keys k
            ON k.operator_id = r.operator_id AND k.key_id = r.signing_key_id
          WHERE r.draw_id = $1
          """,
          [Ecto.UUID.dump!(draw.id)]
        )

      Repo.query!("DELETE FROM operator_receipts WHERE draw_id = $1", [Ecto.UUID.dump!(draw.id)])

      insert_v6_lock_receipt!(draw, draw.entry_hash, draw.entropy_composition, round, %{
        key_id: key_id,
        private_key: private_key
      })

      if Keyword.get(opts, :observation, true) do
        Repo.query!(
          """
          INSERT INTO weather_observations (id, station, observation_time, value, raw, stored_at)
          VALUES ($1, $2, $3, $4, '[]', $3)
          ON CONFLICT DO NOTHING
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Stations.primary().id,
            DateTime.to_naive(wt),
            @test_observation
          ]
        )
      end
    end)

    Draw
    |> Ash.get!(draw.id, authorize?: false)
    |> Ash.Changeset.for_update(:transition_to_pending, %{})
    |> Ash.update!(domain: WallopCore.Domain, authorize?: false)
  end

  @doc """
  A draw as the retired forecast method left it: no lock schema, a stored
  lock receipt (a lock schema 5 payload) and `status`, written with every
  trigger off, since no current code path can lock one. Returns the draw.
  """
  def put_retired_forecast_draw!(api_key, status \\ :completed) do
    draw = open_draw_with_entries(api_key)
    {hash, canonical} = Protocol.entry_hash({draw.id, Entries.load_for_draw(draw.id)})
    operator = Ash.get!(Operator, api_key.operator_id, authorize?: false)
    locked_at = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:microsecond)

    payload =
      Jason.encode!(%{
        "schema_version" => "5",
        "entropy_composition" => "drand-quicknet+openmeteo-v1",
        "draw_id" => draw.id,
        "operator_id" => operator.id,
        "operator_slug" => to_string(operator.slug),
        "sequence" => draw.operator_sequence,
        "entry_hash" => hash
      })

    with_triggers_off(fn ->
      Repo.query!(
        """
        UPDATE draws SET status = $2, entry_hash = $3, entry_canonical = $4,
          drand_chain = $5, drand_round = 1, weather_station = 'middle-wallop',
          weather_time = $6
        WHERE id = $1
        """,
        [
          Ecto.UUID.dump!(draw.id),
          to_string(status),
          hash,
          canonical,
          Quicknet.chain_hash(),
          DateTime.to_naive(DateTime.add(locked_at, 300))
        ]
      )

      Repo.query!(
        """
        INSERT INTO operator_receipts (id, operator_id, draw_id, sequence, commitment_hash,
          entry_hash, locked_at, signing_key_id, payload_jcs, signature, inserted_at)
        VALUES ($1, $2, $3, $4, $5, $5, $6, 'retired0', $7, $8, $6)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(operator.id),
          Ecto.UUID.dump!(draw.id),
          draw.operator_sequence,
          hash,
          DateTime.to_naive(locked_at),
          payload,
          :binary.copy(<<0>>, 64)
        ]
      )
    end)

    Ash.get!(Draw, draw.id, authorize?: false)
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

  @doc """
  A deterministic drand randomness hex value for tests: a real quicknet
  beacon's, the SHA-256 of `test_drand_signature/0`.
  """
  def test_drand_randomness do
    "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  end

  @doc "The quicknet BLS signature `test_drand_randomness/0` is the hash of."
  def test_drand_signature do
    "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"
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

  @doc """
  Revokes one signing key directly, as `WallopCore.KeyRotation` would, but
  without its rule that the current key is never revoked. Returns the key.
  """
  def revoke_key!(%WallopCore.Resources.InfrastructureSigningKey{key_id: key_id} = key) do
    insert_revocation!(%{key_class: :infrastructure, key_id: key_id})
    key
  end

  def revoke_key!(%WallopCore.Resources.OperatorSigningKey{} = key) do
    insert_revocation!(%{key_class: :operator, operator_id: key.operator_id, key_id: key.key_id})
    key
  end

  defp insert_revocation!(attrs) do
    WallopCore.Resources.SigningKeyRevocation
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :reason, "test"))
    |> Ash.create!(authorize?: false)
  end

  @doc "Creates an api_key bound to the given operator."
  def create_api_key_for_operator(operator, name \\ "op-key") do
    WallopCore.Resources.ApiKey
    |> Ash.Changeset.for_create(:create, %{name: name, operator_id: operator.id})
    |> Ash.create!(authorize?: false)
  end

  @doc "An operator on the observation weather protocol, and an API key for it."
  def create_v6_operator do
    put_observation_readiness!(true)
    operator = create_operator()

    {:ok, operator} =
      operator
      |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :observation})
      |> Ash.update(authorize?: false)

    {operator, create_api_key_for_operator(operator)}
  end

  @doc """
  Writes the observation readiness record as the fetching service would:
  `ready`, checked `age_seconds` ago on the database clock. `nil` deletes
  it. `create_v6_operator/0` writes a fresh `true`, so observation locks in
  tests behave as they do with a working fetcher.
  """
  def put_observation_readiness!(ready, age_seconds \\ 0)

  def put_observation_readiness!(nil, _age_seconds) do
    Repo.query!("DELETE FROM observation_readiness")
    :ok
  end

  def put_observation_readiness!(ready, age_seconds) when is_boolean(ready) do
    Repo.query!(
      """
      INSERT INTO observation_readiness (singleton, ready, checked_at)
      VALUES (true, $1, (statement_timestamp() AT TIME ZONE 'UTC') - make_interval(secs => $2))
      ON CONFLICT (singleton) DO UPDATE SET ready = EXCLUDED.ready, checked_at = EXCLUDED.checked_at
      """,
      [ready, age_seconds]
    )

    :ok
  end

  @doc "An operator on the grid-frequency protocol, and an API key for it."
  def create_freq_operator do
    {:ok, operator} =
      create_operator()
      |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :frequency})
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
  lock v6 receipt for it, with every trigger off. Test-only: it lets tests
  place the fetch window around the current time, which a real lock can't
  (it must happen 46 minutes before weather_time).

  The draw row gets `weather_time` and `drand_round` as given. The receipt
  is built by `insert_v6_lock_receipt!/4` from `drand_round` alone, so its
  signed weather_time is `Schedule.weather_time_for_round(drand_round)`.

  **The stored `weather_time` may differ from the signed copy.** Tests that
  build on this (fetch, execution, proof) must assert on the signed value in
  the receipt, or on the value derived from `drand_round`, never on the
  stored `weather_time` as if it had been signed.

  Options:

    * `:entropy_composition` (default: the Land Observations tag);
    * `:freq_start`, the row's grid-frequency window start (default:
      `FreqSchedule.freq_start_for_round(drand_round)`, the value both lock
      schema 6 tags carry; `nil` leaves the column NULL).

  Returns the draw with `expected_result_at` loaded.
  """
  def put_v6_awaiting!(draw, %DateTime{} = weather_time, drand_round, opts \\ [])
      when is_integer(drand_round) do
    tag = Keyword.get(opts, :entropy_composition, Protocol.landobs_entropy_composition())

    freq_start =
      Keyword.get_lazy(opts, :freq_start, fn -> FreqSchedule.freq_start_for_round(drand_round) end)

    entries = Entries.load_for_draw(draw.id)
    {hash, canonical} = Protocol.entry_hash({draw.id, entries})

    with_triggers_off(fn ->
      Repo.query!(
        """
        UPDATE draws SET status = 'awaiting_entropy', lock_schema_version = '6',
          entropy_composition = $7, entry_hash = $2, entry_canonical = $3, drand_chain = $4,
          drand_round = $5, weather_station = $8, weather_time = $6, freq_start = $9
        WHERE id = $1
        """,
        [
          Ecto.UUID.dump!(draw.id),
          hash,
          canonical,
          Quicknet.chain_hash(),
          drand_round,
          DateTime.to_naive(weather_time),
          tag,
          Stations.primary().id,
          freq_start && DateTime.to_naive(freq_start)
        ]
      )

      insert_v6_lock_receipt!(draw, hash, tag, drand_round)
    end)

    Ash.get!(Draw, draw.id, authorize?: false, load: [:expected_result_at])
  end

  @doc """
  Places a stored reading for an observation hour with every trigger off.
  Test-only: the real store refuses any write outside the station's window
  on the database clock, so a test that needs a reading for an hour whose
  window has closed (to execute against it) places it here. The table's
  CHECK constraints still apply.
  """
  def put_observation!(station, %DateTime{} = observation_time, value, raw \\ "[]") do
    with_triggers_off(fn ->
      Repo.query!(
        """
        INSERT INTO weather_observations (id, station, observation_time, value, raw, stored_at)
        VALUES ($1, $2, $3, $4, $5, $3)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          station,
          DateTime.to_naive(observation_time),
          value,
          raw
        ]
      )
    end)

    :ok
  end

  defp with_triggers_off(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("RESET session_replication_role")
    end
  end

  @doc """
  A signed lock v6 receipt for `draw`, inserted with whatever triggers are
  on. Signed weather_time is the round's observation hour; `locked_at` is
  now, or the latest in-time instant if now is too late, and is both the
  signed value and the receipt's `locked_at` column. Signs with the operator's current key, chosen as the
  production lock path chooses it (latest `valid_from` not after now).
  """
  def insert_v6_lock_receipt!(draw, entry_hash, entropy_composition, drand_round, key \\ nil) do
    require Ash.Query

    operator_id = draw.operator_id

    now = DateTime.utc_now()

    key =
      key ||
        OperatorSigningKey
        |> Ash.Query.filter(operator_id == ^operator_id and valid_from <= ^now)
        |> Ash.Query.sort(valid_from: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!(authorize?: false)
        |> hd()

    {:ok, private} = Vault.decrypt(key.private_key)
    operator = Ash.get!(Operator, operator_id, authorize?: false)
    signed_wt = Schedule.weather_time_for_round(drand_round)

    locked_at =
      Enum.min(
        [DateTime.truncate(now, :microsecond), Schedule.latest_lock_at(signed_wt)],
        DateTime
      )

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
        freq_start: FreqSchedule.freq_start_for_round(drand_round),
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

  @doc """
  A valid execution receipt schema 5 input under the Land Obs tag, in
  state (a): Middle Wallop's reading for the hour of drand round
  33_068_212 (publishes 2026-10-14 20:00:00Z; observation hour 19:00:00Z),
  no fallback reason and no grid-frequency fields. Not tied to any row.
  """
  def landobs_exec_input do
    %{
      entropy_composition: "drand-quicknet+metoffice-landobs-v1",
      draw_id: "22222222-2222-2222-2222-222222222222",
      operator_id: "11111111-1111-1111-1111-111111111111",
      operator_slug: "acme-prizes",
      sequence: 7,
      lock_receipt_hash: String.duplicate("cd", 32),
      entry_hash: String.duplicate("ab", 32),
      drand_chain: "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971",
      drand_round: 33_068_212,
      drand_randomness: "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd",
      drand_signature:
        "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf",
      weather_station: "wmo-03749",
      weather_observation_time: ~U[2026-10-14 19:00:00.000000Z],
      weather_value: "141;1025;85;2432",
      weather_fallback_reason: nil,
      freq_value: nil,
      freq_fallback_reason: nil,
      wallop_core_version: "0.29.0",
      fair_pick_version: Application.spec(:fair_pick, :vsn) |> to_string(),
      seed: String.duplicate("ef", 32),
      results: ["33333333-3333-3333-3333-333333333333"],
      executed_at: ~U[2026-10-14 20:00:06.000000Z],
      signing_key_id: "cafebabe"
    }
  end

  @doc "The 15-second boundary at or before now + `offset_seconds`."
  def aligned_freq_start(offset_seconds) do
    u = DateTime.to_unix(DateTime.utc_now()) + offset_seconds
    DateTime.from_unix!((u - Integer.mod(u, 15)) * 1_000_000, :microsecond)
  end

  @doc """
  An Elexon FREQ response body holding the 8 readings of `value` for the
  window starting at `freq_start`, newest first, as Elexon sends them.
  """
  def elexon_body(%DateTime{} = freq_start, value) when is_binary(value) do
    rows =
      value
      |> String.split(";")
      |> Enum.with_index(fn mhz, i ->
        n = String.to_integer(mhz)

        text =
          "#{div(n, 1000)}.#{n |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0")}"

        stamp = Calendar.strftime(DateTime.add(freq_start, 15 * i), "%Y-%m-%dT%H:%M:%SZ")
        ~s({"dataset":"FREQ","measurementTime":"#{stamp}","frequency":#{text}})
      end)
      |> Enum.reverse()

    ~s({"data":[#{Enum.join(rows, ",")}]})
  end

  @doc """
  Puts an open draw into awaiting_entropy as a grid-frequency draw with the
  given `freq_start` and `drand_round`, and stores a signed lock receipt,
  with every trigger off, like `put_v6_awaiting!/4`, so tests can place the
  store window around now.

  **The stored `freq_start` may differ from the signed copy**, which is the
  round's own window start. Assert on the signed value, or on the one
  derived from `drand_round`.
  """
  def put_freq_awaiting!(draw, %DateTime{} = freq_start, drand_round)
      when is_integer(drand_round) do
    {hash, canonical} = Protocol.entry_hash({draw.id, Entries.load_for_draw(draw.id)})

    with_triggers_off(fn ->
      Repo.query!(
        """
        UPDATE draws SET status = 'awaiting_entropy', lock_schema_version = '6',
          entropy_composition = $7, entry_hash = $2, entry_canonical = $3, drand_chain = $4,
          drand_round = $5, freq_start = $6, weather_station = NULL, weather_time = NULL
        WHERE id = $1
        """,
        [
          Ecto.UUID.dump!(draw.id),
          hash,
          canonical,
          Quicknet.chain_hash(),
          drand_round,
          DateTime.to_naive(freq_start),
          Protocol.freq_entropy_composition()
        ]
      )

      insert_freq_lock_receipt!(draw, hash, drand_round)
    end)

    Ash.get!(Draw, draw.id, authorize?: false, load: [:expected_result_at])
  end

  @doc """
  A signed grid-frequency lock receipt for `draw`, inserted with whatever
  triggers are on. The signed `freq_start` is the round's window start;
  `locked_at` is now, or the latest in-time instant if now is too late.
  Signs with the operator's current key, as the lock path chooses it.
  """
  def insert_freq_lock_receipt!(draw, entry_hash, drand_round) do
    require Ash.Query

    operator_id = draw.operator_id
    now = DateTime.utc_now()

    [key] =
      OperatorSigningKey
      |> Ash.Query.filter(operator_id == ^operator_id and valid_from <= ^now)
      |> Ash.Query.sort(valid_from: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    {:ok, private} = Vault.decrypt(key.private_key)
    operator = Ash.get!(Operator, operator_id, authorize?: false)
    signed_start = FreqSchedule.freq_start_for_round(drand_round)

    locked_at =
      Enum.min(
        [DateTime.truncate(now, :microsecond), FreqSchedule.latest_lock_at(signed_start)],
        DateTime
      )

    payload =
      Protocol.build_v6_lock_payload(%{
        entropy_composition: Protocol.freq_entropy_composition(),
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
        weather_station: nil,
        weather_time: nil,
        freq_start: signed_start,
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

  @doc """
  Places T's window with every trigger off (tests only), for a T whose
  window has closed, as `put_observation!/4` does for an hour. The CHECKs
  still apply.
  """
  def put_frequency_window!(%DateTime{} = freq_start, value) do
    with_triggers_off(fn ->
      Repo.query!(
        "INSERT INTO frequency_windows (id, freq_start, value, raw, stored_at) VALUES ($1, $2, $3, $4, $2)",
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          DateTime.to_naive(freq_start),
          value,
          elexon_body(freq_start, value)
        ]
      )
    end)

    :ok
  end
end
