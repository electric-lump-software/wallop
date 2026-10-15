defmodule WallopCore.InvariantCase do
  @moduledoc """
  Case template and helpers for the protocol invariant suite in
  `test/wallop_core/invariants/`. The suite's rules are in the moduledoc of
  `WallopCore.Invariants.SuiteTest` (`invariants/invariants_test.exs`).

  `use WallopCore.InvariantCase` is `use WallopCore.DataCase` plus:

    * the helpers below, imported;
    * a `test` macro that marks a pending invariant (one tagged with one of
      `pending_tags/0`) as skipped when the run includes it only through
      another tag, such as `mix test --only invariant`. A normal run excludes
      it (see `test_helper.exs`); `--only pending_task_N` runs it for real.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.LandObs
  alias WallopCore.Repo
  alias WallopCore.Resources.{Operator, OperatorSigningKey}
  alias WallopCore.Weather.{Schedule, Stations}

  # One tag per task that still owes the suite an invariant. A task removes
  # its tag from the tests it delivers; once no test uses a tag, it may be
  # removed here too.
  @pending_tags [:pending_task_6, :pending_task_10, :pending_task_11, :pending_task_18]

  @doc "Tags of invariants whose task has not landed. Excluded by default."
  def pending_tags, do: @pending_tags

  defmacro __using__(opts) do
    quote do
      use WallopCore.DataCase, unquote(opts)
      import ExUnit.Case, except: [test: 1, test: 2, test: 3]
      import WallopCore.InvariantCase, except: [__using__: 1, __skip_if_pending__: 1]
      import WallopCore.TestHelpers
    end
  end

  @doc false
  defmacro test(message, var \\ quote(do: _), contents) do
    quote do
      WallopCore.InvariantCase.__skip_if_pending__(__MODULE__)
      ExUnit.Case.test(unquote(message), unquote(var), unquote(contents))
    end
  end

  @doc false
  def __skip_if_pending__(module) do
    tags = module |> Module.get_attribute(:tag) |> List.wrap() |> Enum.flat_map(&tag_keys/1)
    include = ExUnit.configuration() |> Keyword.get(:include, []) |> Enum.flat_map(&tag_keys/1)

    case Enum.filter(tags, &(&1 in @pending_tags and &1 not in include)) do
      [] -> :ok
      pending -> Module.put_attribute(module, :tag, skip: "pending: #{Enum.join(pending, ", ")}")
    end
  end

  defp tag_keys(tag) when is_atom(tag), do: [tag]
  defp tag_keys({key, _value}) when is_atom(key), do: [key]
  defp tag_keys(tags) when is_list(tags), do: Enum.flat_map(tags, &tag_keys/1)
  defp tag_keys(_), do: []

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

    # The latest whole hour h with h - 46m < now.
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
    entry_hash = $9, entry_canonical = $10
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
      canonical
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

  @doc """
  A lock v6 payload (decoded) and receipt columns that pass every guard for
  `draw` once it is locked under schedule `s`, built by the real builder.
  Signed `locked_at` is now: after the operator's key entered the keyring,
  and in time for `s`.
  """
  def valid_receipt(draw, s) do
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
    locked_at = DateTime.utc_now()

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
        wallop_core_version: "0.0.0",
        fair_pick_version: "0.0.0"
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
  Tries to insert a receipt row as given, always rolled back. Returns nil
  when accepted, or the refusal's message. The database does not check the
  signature, so it is a placeholder.
  """
  def insert_receipt(payload, cols) do
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
        Jason.encode!(payload),
        :binary.copy(<<0>>, 64)
      ]
    )
  end

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
