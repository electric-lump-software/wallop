defmodule WallopCore.InvariantCase do
  @moduledoc """
  Case template and helpers for the protocol invariant suite in
  `test/wallop_core/invariants/`. The suite's rules are in the moduledoc of
  `WallopCore.Invariants.SuiteTest` (`invariants/invariants_test.exs`).

  `use WallopCore.InvariantCase` is `use WallopCore.DataCase` plus the
  helpers below and `WallopCore.TestHelpers`, imported.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.Schedule, as: FreqSchedule
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.{Freq, LandObs}
  alias WallopCore.Repo
  alias WallopCore.Resources.{Operator, OperatorSigningKey}
  alias WallopCore.Weather.{Schedule, Stations}

  import WallopCore.TestHelpers,
    only: [
      create_freq_operator: 0,
      create_v6_operator: 0,
      ensure_infrastructure_key: 0,
      open_draw_with_entries: 1,
      put_freq_awaiting!: 3,
      put_frequency_window!: 2,
      put_observation!: 3,
      put_v6_awaiting!: 4
    ]

  @pending_tags []

  @doc "Tags of invariants whose task has not landed. Excluded by default."
  def pending_tags, do: @pending_tags

  defmacro __using__(opts) do
    quote do
      use WallopCore.DataCase, unquote(opts)
      import WallopCore.InvariantCase, except: [__using__: 1]
      import WallopCore.TestHelpers
    end
  end

  @doc "A schedule whose latest lock time is still ahead: a lock now is in time."
  def in_time_schedule do
    {:ok, s} = Schedule.schedule(Schedule.default_draw_at(DateTime.utc_now()))
    s
  end

  @doc """
  Schedules whose latest lock time has passed on any clock: the most recent
  observation hour that is already too late, and one about four hours ago.
  """
  def missed_schedules do
    now = DateTime.utc_now()
    w = Schedule.fetch_window_seconds()

    latest = DateTime.to_unix(now) + Schedule.lock_offset_seconds() - 1
    h = DateTime.from_unix!((latest - Integer.mod(latest, 3600)) * 1_000_000, :microsecond)

    for wt <- [h, DateTime.add(h, -4 * 3600)] do
      round = Quicknet.round_at_or_after(DateTime.add(wt, w + 60))
      {:ok, s} = Schedule.schedule(Quicknet.pub_time(round))
      ^wt = s.weather_time
      s
    end
  end

  @doc """
  Runs `sql` in a savepoint that is always rolled back. Returns nil when the
  database accepted it, or the refusal's message. Nothing it does persists.
  """
  def try_sql(sql, params) do
    {:error, :accepted} =
      Repo.transaction(fn ->
        Repo.query!(sql, params)
        Repo.rollback(:accepted)
      end)

    nil
  rescue
    e in Postgrex.Error -> e.postgres.message
  end

  @lock_sql """
  UPDATE draws SET status = $5, lock_schema_version = $6, entropy_composition = $7,
    drand_chain = $8, drand_round = $2, weather_time = $3, weather_station = $4,
    entry_hash = $9, entry_canonical = $10, freq_start = $11
  WHERE id = $1
  """

  @doc """
  The v6 lock as a raw UPDATE, kept when the database accepts it. Returns
  nil when accepted, or the refusal's message.
  """
  def raw_lock(draw, wt, round, overrides \\ []) do
    o =
      Keyword.merge(
        [
          station: Stations.primary().id,
          status: "awaiting_entropy",
          schema: "6",
          tag: LandObs.tag(),
          chain: Quicknet.chain_hash()
        ],
        overrides
      )

    freq_start =
      Keyword.get_lazy(overrides, :freq_start, fn ->
        if o[:tag] == LandObs.tag(), do: FreqSchedule.freq_start_for_round(round)
      end)

    {hash, canonical} = entry_hash(draw)

    params = [
      dump(draw.id),
      round,
      DateTime.to_naive(wt),
      o[:station],
      o[:status],
      o[:schema],
      o[:tag],
      o[:chain],
      hash,
      canonical,
      freq_start && DateTime.to_naive(freq_start)
    ]

    Repo.transaction(fn -> Repo.query!(@lock_sql, params) end)
    nil
  rescue
    e in Postgrex.Error -> e.postgres.message
  end

  def entry_hash(draw),
    do: Protocol.entry_hash({draw.id, WallopCore.Entries.load_for_draw(draw.id)})

  def dump(id), do: Ecto.UUID.dump!(id)

  def rfc(dt), do: WallopCore.Time.to_rfc3339_usec(dt)

  @doc "The instant `dt` written with a `+0h:00` offset instead of `Z`, `h` in 0..9."
  def offset_rfc(dt, h) when h in 0..9,
    do: dt |> DateTime.add(h * 3600) |> rfc() |> String.replace_suffix("Z", "+0#{h}:00")

  @doc "The trigger's refusal of a signed time that isn't canonical UTC."
  def not_canonical(text), do: "not a canonical UTC timestamp: " <> text

  @doc """
  A lock v6 payload (decoded) and receipt columns that pass every guard for
  `draw` once it is locked under schedule `s`, built by the real builder.
  Signed `locked_at` is now by default: after the operator's key entered the
  keyring, and in time for `s`. Pass `locked_at` to sign another instant.
  """
  def valid_receipt(draw, s, locked_at \\ DateTime.utc_now()) do
    require Ash.Query

    operator = Ash.get!(Operator, draw.operator_id, authorize?: false)
    operator_id = operator.id

    key =
      OperatorSigningKey
      |> Ash.Query.filter(operator_id == ^operator_id)
      |> Ash.Query.sort(valid_from: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    {hash, _} = entry_hash(draw)

    payload =
      %{
        entropy_composition: LandObs.tag(),
        operator_id: operator.id,
        operator_slug: to_string(operator.slug),
        sequence: draw.operator_sequence,
        draw_id: draw.id,
        commitment_hash: hash,
        entry_hash: hash,
        locked_at: locked_at,
        signing_key_id: key.key_id,
        winner_count: draw.winner_count,
        drand_chain: Quicknet.chain_hash(),
        drand_round: s.round,
        weather_station: Stations.primary().id,
        weather_time: s.weather_time,
        freq_start: FreqSchedule.freq_start_for_round(s.round),
        wallop_core_version: "0.0.0",
        fair_pick_version: to_string(Application.spec(:fair_pick, :vsn))
      }
      |> Protocol.build_v6_lock_payload()
      |> Jason.decode!()

    cols = %{
      operator_id: operator.id,
      sequence: draw.operator_sequence,
      commitment_hash: hash,
      entry_hash: hash,
      locked_at: locked_at,
      signing_key_id: key.key_id,
      draw_id: draw.id
    }

    {payload, cols}
  end

  @doc "A grid-frequency schedule whose latest lock time is still ahead."
  def in_time_freq_schedule do
    {:ok, s} = FreqSchedule.schedule(FreqSchedule.default_draw_at(DateTime.utc_now()))
    s
  end

  @freq_lock_sql """
  UPDATE draws SET status = $2, lock_schema_version = $3, entropy_composition = $4,
    drand_chain = $5, drand_round = $6, freq_start = $7, weather_station = $8, weather_time = $9,
    entry_hash = $10, entry_canonical = $11
  WHERE id = $1
  """

  @doc """
  The grid-frequency lock as a raw UPDATE, kept when the database accepts
  it. Returns nil when accepted, or the refusal's message. The UPDATE runs
  in `Repo.transaction/1`, a savepoint inside an outer transaction, so the
  outer transaction's commit is what a deferred trigger sees.
  """
  def raw_freq_lock(draw, s, overrides \\ []) do
    o =
      Keyword.merge(
        [
          status: "awaiting_entropy",
          schema: "6",
          tag: Freq.tag(),
          chain: Quicknet.chain_hash(),
          round: s.round,
          freq_start: s.freq_start,
          station: nil,
          weather_time: nil
        ],
        overrides
      )

    {hash, canonical} = entry_hash(draw)

    params = [
      dump(draw.id),
      o[:status],
      o[:schema],
      o[:tag],
      o[:chain],
      o[:round],
      o[:freq_start] && DateTime.to_naive(o[:freq_start]),
      o[:station],
      o[:weather_time] && DateTime.to_naive(o[:weather_time]),
      hash,
      canonical
    ]

    Repo.transaction(fn -> Repo.query!(@freq_lock_sql, params) end)
    nil
  rescue
    e in Postgrex.Error -> e.postgres.message
  end

  @doc """
  A grid-frequency lock v6 payload (decoded) and receipt columns that pass
  every guard for `draw` once it is locked under `s`, built by the real
  builder and signed at `locked_at` (now by default) with the operator's
  current key.
  """
  def valid_freq_receipt(draw, s, locked_at \\ DateTime.utc_now()) do
    require Ash.Query

    operator = Ash.get!(Operator, draw.operator_id, authorize?: false)
    operator_id = operator.id

    key =
      OperatorSigningKey
      |> Ash.Query.filter(operator_id == ^operator_id)
      |> Ash.Query.sort(valid_from: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    {hash, _} = entry_hash(draw)

    payload =
      %{
        entropy_composition: Freq.tag(),
        operator_id: operator.id,
        operator_slug: to_string(operator.slug),
        sequence: draw.operator_sequence,
        draw_id: draw.id,
        commitment_hash: hash,
        entry_hash: hash,
        locked_at: locked_at,
        signing_key_id: key.key_id,
        winner_count: draw.winner_count,
        drand_chain: Quicknet.chain_hash(),
        drand_round: s.round,
        weather_station: nil,
        weather_time: nil,
        freq_start: s.freq_start,
        wallop_core_version: "0.0.0",
        fair_pick_version: to_string(Application.spec(:fair_pick, :vsn))
      }
      |> Protocol.build_v6_lock_payload()
      |> Jason.decode!()

    cols = %{
      operator_id: operator.id,
      sequence: draw.operator_sequence,
      commitment_hash: hash,
      entry_hash: hash,
      locked_at: locked_at,
      signing_key_id: key.key_id,
      draw_id: draw.id
    }

    {payload, cols}
  end

  @doc """
  Inserts a lock receipt row as given and keeps it. A test turns triggers
  off around it to place a receipt before the lock, as if it had slipped in.
  """
  def keep_receipt!(payload, cols) do
    Repo.query!(
      """
      INSERT INTO operator_receipts (id, operator_id, draw_id, sequence, commitment_hash,
        entry_hash, locked_at, signing_key_id, payload_jcs, signature, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $7)
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(cols.operator_id),
        dump(cols.draw_id),
        cols.sequence,
        cols.commitment_hash,
        cols.entry_hash,
        DateTime.to_naive(cols.locked_at),
        cols.signing_key_id,
        Jason.encode!(payload),
        :binary.copy(<<0>>, 64)
      ]
    )
  end

  @doc """
  Tries to insert a receipt row as given, always rolled back. Returns nil
  when accepted, or the refusal's message. The database does not check the
  signature, so it is a placeholder.
  """
  def insert_receipt(payload, cols), do: insert_receipt_json(Jason.encode!(payload), cols)

  @doc "`insert_receipt/2` with the payload bytes given as they are."
  def insert_receipt_json(json, cols) do
    try_sql(
      """
      INSERT INTO operator_receipts (id, operator_id, draw_id, sequence, commitment_hash,
        entry_hash, locked_at, signing_key_id, payload_jcs, signature, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $7)
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(cols.operator_id),
        dump(cols.draw_id),
        cols.sequence,
        cols.commitment_hash,
        cols.entry_hash,
        DateTime.to_naive(cols.locked_at),
        cols.signing_key_id,
        json,
        :binary.copy(<<0>>, 64)
      ]
    )
  end

  @doc """
  A grid-frequency draw completed the way execution leaves it, ready for
  its execution receipt. Its round published about ten seconds ago (plus
  `opts[:minutes_ago]`), so F + M has passed. `kind` is `:observed` (T's
  window, `opts[:value]`, is stored) or `:fallback`. `opts[:freq_start]`
  stores another T (the receipt still signs the round's own), and
  `opts[:triggers_off]` completes with every trigger off, for placing a
  state the draws guard would refuse.

  Returns `%{draw, input, cols, round, freq_start}` like
  `completed_v6_receipt_input/2`.
  """
  def completed_freq_receipt_input(kind, opts \\ []) when kind in [:observed, :fallback] do
    require Ash.Query

    value = Keyword.get(opts, :value, "50012;50018;50012;49983;49980;49953;49912;49883")
    api_key = Keyword.get_lazy(opts, :api_key, fn -> elem(create_freq_operator(), 1) end)
    ensure_infrastructure_key()

    round =
      Quicknet.round_at_or_after(
        DateTime.add(DateTime.utc_now(), -10 - Keyword.get(opts, :minutes_ago, 0) * 60)
      )

    t = Keyword.get(opts, :freq_start, FreqSchedule.freq_start_for_round(round))
    draw = put_freq_awaiting!(open_draw_with_entries(api_key), t, round)
    if kind == :observed, do: put_frequency_window!(t, value)
    complete = if opts[:triggers_off], do: &with_triggers_off/1, else: & &1.()

    executed_at = DateTime.utc_now()
    ids = draw.id |> WallopCore.Entries.load_for_draw() |> Enum.map(& &1.uuid)
    winners = Enum.take(Enum.reverse(ids), 2)

    results =
      winners
      |> Enum.with_index(1)
      |> Enum.map(fn {id, p} -> %{"position" => p, "entry_id" => id} end)

    seed = :crypto.hash(:sha256, draw.id) |> Base.encode16(case: :lower)
    signature = String.duplicate("cd", 48)

    randomness =
      :crypto.hash(:sha256, Base.decode16!(signature, case: :lower))
      |> Base.encode16(case: :lower)

    {freq_value, reason} =
      case kind do
        :observed -> {value, nil}
        :fallback -> {nil, Freq.fallback_reason()}
      end

    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])

    complete.(fn ->
      Repo.query!(
        """
        UPDATE draws SET status = 'completed', executed_at = $2, seed = $3, seed_source = 'entropy',
          results = $4, drand_randomness = $5, drand_signature = $6, freq_value = $7,
          freq_fallback_reason = $8
        WHERE id = $1
        """,
        [
          dump(draw.id),
          DateTime.to_naive(executed_at),
          seed,
          results,
          randomness,
          signature,
          freq_value,
          reason
        ]
      )
    end)

    draw_id = draw.id

    lock =
      WallopCore.Resources.OperatorReceipt
      |> Ash.Query.filter(draw_id == ^draw_id)
      |> Ash.read_one!(authorize?: false)

    lock_payload = Jason.decode!(lock.payload_jcs)
    lock_hash = :crypto.hash(:sha256, lock.payload_jcs) |> Base.encode16(case: :lower)

    infra =
      WallopCore.Resources.InfrastructureSigningKey
      |> Ash.Query.filter(valid_from <= ^executed_at)
      |> Ash.Query.sort(valid_from: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    input = %{
      entropy_composition: draw.entropy_composition,
      draw_id: draw.id,
      operator_id: draw.operator_id,
      operator_slug: lock_payload["operator_slug"],
      sequence: draw.operator_sequence,
      lock_receipt_hash: lock_hash,
      entry_hash: draw.entry_hash,
      drand_chain: draw.drand_chain,
      drand_round: round,
      drand_randomness: randomness,
      drand_signature: signature,
      weather_station: nil,
      weather_observation_time: nil,
      weather_value: nil,
      weather_fallback_reason: nil,
      freq_value: freq_value,
      freq_fallback_reason: reason,
      wallop_core_version: to_string(Application.spec(:wallop_core, :vsn)),
      fair_pick_version: lock_payload["fair_pick_version"],
      seed: seed,
      results: winners,
      executed_at: executed_at,
      signing_key_id: infra.key_id
    }

    cols = %{
      draw_id: draw.id,
      operator_id: draw.operator_id,
      sequence: draw.operator_sequence,
      lock_receipt_hash: lock_hash,
      signing_key_id: infra.key_id
    }

    %{draw: draw, input: input, cols: cols, round: round, freq_start: t}
  end

  @doc """
  A v6 draw completed the way execution leaves it, ready for its execution
  receipt, built through every draws guard. Its round published a few
  seconds ago and its weather_time is that round's observation hour, so the
  fetch deadline and the fallback grace have passed. `kind` is one of the
  tag's three states: `:observed`, state (a) (a reading from
  `opts[:station]`, default the primary, with `opts[:value]`, is stored
  for the hour); `:frequency`, state (b) (no reading; the round's window,
  `opts[:freq_value]`, is stored); or `:fallback`, state (c) (nothing
  stored). `opts[:freq_start]` stores another freq_start, as
  `put_v6_awaiting!/4` takes it.
  `opts[:hours_ago]` moves the round that many hours back, so several
  draws in one test can each have an hour of their own. `opts[:weather_time]`
  stores another weather_time (the receipt still signs the round's own
  hour), and `opts[:triggers_off]` completes the draw with every trigger
  off, for placing a state the draws guard would refuse.

  Returns `%{draw, input, cols, round, wt, exec_after}`: `input` is the
  execution v5 builder input the signer would build from the draw, `cols`
  the receipt row's columns, `exec_after` the µs from pub(R) to
  `executed_at`.
  """
  def completed_v6_receipt_input(kind, opts \\ [])
      when kind in [:observed, :frequency, :fallback] do
    require Ash.Query

    station = Keyword.get(opts, :station, Stations.primary().id)
    value = Keyword.get(opts, :value, "141;1025;85;2432")
    api_key = Keyword.get_lazy(opts, :api_key, fn -> elem(create_v6_operator(), 1) end)
    hours_ago = Keyword.get(opts, :hours_ago, 0)
    ensure_infrastructure_key()

    round =
      Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10 - hours_ago * 3600))

    wt = Keyword.get(opts, :weather_time, Schedule.weather_time_for_round(round))
    freq_value = Keyword.get(opts, :freq_value, "50012;50018;50012;49983;49980;49953;49912;49883")
    awaiting = Keyword.take(opts, [:freq_start])
    draw = put_v6_awaiting!(open_draw_with_entries(api_key), wt, round, awaiting)
    if kind == :observed, do: put_observation!(station, wt, value)
    if kind == :frequency, do: put_frequency_window!(draw.freq_start, freq_value)
    complete = if opts[:triggers_off], do: &with_triggers_off/1, else: & &1.()

    executed_at = DateTime.utc_now()
    ids = draw.id |> WallopCore.Entries.load_for_draw() |> Enum.map(& &1.uuid)
    winners = Enum.take(Enum.reverse(ids), 2)

    results =
      winners
      |> Enum.with_index(1)
      |> Enum.map(fn {id, p} -> %{"position" => p, "entry_id" => id} end)

    seed = :crypto.hash(:sha256, draw.id) |> Base.encode16(case: :lower)
    signature = String.duplicate("cd", 48)

    randomness =
      :crypto.hash(:sha256, Base.decode16!(signature, case: :lower))
      |> Base.encode16(case: :lower)

    {obs_value, obs_time, reason, exec_station, freq, freq_reason} =
      case kind do
        :observed ->
          {value, wt, nil, station, nil, nil}

        :frequency ->
          {nil, nil, LandObs.fallback_reason(), Stations.primary().id, freq_value, nil}

        :fallback ->
          {nil, nil, LandObs.fallback_reason(), Stations.primary().id, nil,
           Protocol.freq_fallback_reason()}
      end

    Repo.query!("UPDATE draws SET status = 'pending_entropy' WHERE id = $1", [dump(draw.id)])

    complete.(fn ->
      Repo.query!(
        """
        UPDATE draws SET status = 'completed', executed_at = $2, seed = $3, seed_source = 'entropy',
          results = $4, drand_randomness = $5, drand_signature = $6, weather_value = $7,
          weather_observation_time = $8, weather_fallback_reason = $9, freq_value = $10,
          freq_fallback_reason = $11
        WHERE id = $1
        """,
        [
          dump(draw.id),
          DateTime.to_naive(executed_at),
          seed,
          results,
          randomness,
          signature,
          obs_value,
          obs_time && DateTime.to_naive(obs_time),
          reason,
          freq,
          freq_reason
        ]
      )
    end)

    draw_id = draw.id

    lock =
      WallopCore.Resources.OperatorReceipt
      |> Ash.Query.filter(draw_id == ^draw_id)
      |> Ash.read_one!(authorize?: false)

    lock_payload = Jason.decode!(lock.payload_jcs)
    lock_hash = :crypto.hash(:sha256, lock.payload_jcs) |> Base.encode16(case: :lower)

    infra =
      WallopCore.Resources.InfrastructureSigningKey
      |> Ash.Query.filter(valid_from <= ^executed_at)
      |> Ash.Query.sort(valid_from: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    input = %{
      entropy_composition: draw.entropy_composition,
      draw_id: draw.id,
      operator_id: draw.operator_id,
      operator_slug: lock_payload["operator_slug"],
      sequence: draw.operator_sequence,
      lock_receipt_hash: lock_hash,
      entry_hash: draw.entry_hash,
      drand_chain: draw.drand_chain,
      drand_round: round,
      drand_randomness: randomness,
      drand_signature: signature,
      weather_station: exec_station,
      weather_observation_time: obs_time,
      weather_value: obs_value,
      weather_fallback_reason: reason,
      freq_value: freq,
      freq_fallback_reason: freq_reason,
      wallop_core_version: to_string(Application.spec(:wallop_core, :vsn)),
      fair_pick_version: lock_payload["fair_pick_version"],
      seed: seed,
      results: winners,
      executed_at: executed_at,
      signing_key_id: infra.key_id
    }

    cols = %{
      draw_id: draw.id,
      operator_id: draw.operator_id,
      sequence: draw.operator_sequence,
      lock_receipt_hash: lock_hash,
      signing_key_id: infra.key_id
    }

    %{
      draw: draw,
      input: input,
      cols: cols,
      round: round,
      wt: wt,
      exec_after: DateTime.diff(executed_at, Quicknet.pub_time(round), :microsecond)
    }
  end

  @doc """
  Tries to insert an execution receipt row with payload bytes `json` and
  the given columns, always rolled back. Returns nil when accepted, or the
  refusal's message. The signature is a placeholder.
  """
  def insert_exec_receipt(json, cols) do
    try_sql(
      """
      INSERT INTO execution_receipts (id, draw_id, operator_id, sequence, lock_receipt_hash,
        payload_jcs, signature, signing_key_id)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      """,
      [
        dump(Ecto.UUID.generate()),
        dump(cols.draw_id),
        dump(cols.operator_id),
        cols.sequence,
        cols.lock_receipt_hash,
        json,
        :binary.copy(<<0>>, 64),
        cols.signing_key_id
      ]
    )
  end

  @doc """
  The text of an error from an Ash call or the database, for pinning the
  refusal's message: an exception's message, or the inspected term.
  """
  def error_text(%{__exception__: true} = e), do: Exception.message(e)
  def error_text(other), do: inspect(other)

  @doc "Runs `fun` with every trigger off, for placing test state directly."
  def with_triggers_off(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("RESET session_replication_role")
    end
  end
end
