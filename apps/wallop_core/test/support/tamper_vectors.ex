defmodule WallopCore.TamperVectors do
  @moduledoc """
  Builds the tamper vectors: signed lock v6 / execution v5 proof bundles,
  each with exactly one signed field tampered. One file per entropy tag:

    * `spec/vectors/proof-bundle-v6-tamper.json`, the Land Observations tag
      (`WallopCore.TamperProfiles.LandObs`);
    * `spec/vectors/proof-bundle-v6-tamper-freq.json`, the grid-frequency
      tag (`WallopCore.TamperProfiles.Freq`).

  What differs by tag (the input fields, `locked_at`, the seed, the
  unsigned entropy key, the base names, the key sets and the cases) lives in
  the tag's `WallopCore.TamperProfiles` module. Everything else is shared
  and lives here: the real quicknet round and its beacon, `executed_at`, the
  draw and its entries, the deterministic keys, the envelope, re-signing and
  `put_field/3`.

  Every bundle starts from a valid base built by the real builders
  (`Protocol.build_v6_lock_payload/1`, `Protocol.build_v6_execution_payload/1`)
  on a real quicknet round. One field of one receipt is then changed and
  the receipt is signed again with the vector key, so the signature always
  verifies and only the semantic checks can refuse the bundle. When the lock
  receipt is changed, the execution receipt's `lock_receipt_hash` is
  recomputed and the execution receipt signed again too, so the linkage
  holds and the tampered field is the only change a verifier can see.

  Each case names the exact set of verifier steps (snake_case `StepName`)
  expected to fail. The keys are carried inline at the top level, as
  `[{key_id, public_key_hex, key_class, inserted_at}]`.

  Regenerate with:

      MIX_ENV=test mix run apps/wallop_core/test/wallop_core/tamper_vectors_generator.exs

  `WallopCore.Invariants.TamperTest` checks each committed file equals
  `encode/1`, and that each case changes exactly one signed field.

  The functions without a profile argument (`path/0`, `base/1`,
  `lock_input/0`, `exec_input/2`, `cases/0`, `locked_at/0`) keep their Land
  Obs meaning.
  """

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Protocol
  alias WallopCore.TamperProfiles

  @dir Path.expand("../../../../spec/vectors", __DIR__)
  @profiles [TamperProfiles.LandObs, TamperProfiles.Freq]

  # A real quicknet beacon, published 2026-10-14T20:00:00Z; the same round
  # the v6 builder tests use. Its observation hour is 19:00; its
  # grid-frequency window starts at 19:54:00.
  @round 33_068_212
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @signature "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"
  @executed_at ~U[2026-10-14 20:00:06.000000Z]
  @key_inserted_at "2026-10-01T00:00:00.000000Z"

  @draw_id "dddddddd-2222-4222-8222-222222222222"
  @operator_id "11111111-1111-4111-8111-111111111111"
  @entries [
    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  ]
  @winner_count 2

  @mainnet_chain "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce"
  @forecast_tag "drand-quicknet+openmeteo-v1"
  @other_uuid "33333333-3333-4333-8333-333333333333"
  @other_hash String.duplicate("ab", 32)

  @doc "Every tag's profile, in the order the vector files are written."
  def profiles, do: @profiles

  @doc "Where `profile`'s vector file lives (the Land Obs file by default)."
  def path(profile \\ TamperProfiles.LandObs), do: Path.join(@dir, profile.vector_file())

  @doc """
  The fair_pick release both receipts sign: the running dependency's
  version, as the lock and execution paths sign it. Never hard-coded; the
  verifier accepts only releases it knows.
  """
  def fair_pick_version, do: Application.spec(:fair_pick, :vsn) |> to_string()

  @doc "The vector's real quicknet round."
  def round, do: @round

  @doc "The Land Obs vector's signed `locked_at`; every tag's `executed_at`."
  def locked_at, do: TamperProfiles.LandObs.locked_at()
  def executed_at, do: @executed_at

  @doc "Shared values the profiles' cases use."
  def mainnet_chain, do: @mainnet_chain
  def forecast_tag, do: @forecast_tag
  def other_uuid, do: @other_uuid
  def other_hash, do: @other_hash
  def winner_count, do: @winner_count

  @doc """
  The two deterministic vector keys, `{private, public, key_id}`, from the
  seeds `sha256("wallop-vector-operator-key")` and
  `sha256("wallop-vector-infrastructure-key")`.
  """
  def operator_key, do: key("wallop-vector-operator-key")
  def infrastructure_key, do: key("wallop-vector-infrastructure-key")

  defp key(label) do
    seed = :crypto.hash(:sha256, label)
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {seed, public, Protocol.key_id(public)}
  end

  @doc "The entry hash every vector bundle commits to."
  def entry_hash do
    {hash, _} =
      Protocol.entry_hash({@draw_id, Enum.map(@entries, &%{uuid: &1, weight: 1})})

    hash
  end

  @doc "Builder input for `profile`'s base lock receipt."
  def lock_input(profile \\ TamperProfiles.LandObs) do
    {_, _, kid} = operator_key()

    Map.merge(
      %{
        operator_id: @operator_id,
        operator_slug: "acme-prizes",
        sequence: 7,
        draw_id: @draw_id,
        commitment_hash: entry_hash(),
        entry_hash: entry_hash(),
        signing_key_id: kid,
        winner_count: @winner_count,
        drand_chain: Quicknet.chain_hash(),
        drand_round: @round,
        wallop_core_version: "0.29.0",
        fair_pick_version: fair_pick_version()
      },
      profile.lock_fields()
    )
  end

  @doc """
  Builder input for `profile`'s base execution receipt, one of
  `profile.kinds()`, linked to `lock_jcs`. The seed and results are computed, so
  they agree.
  """
  def exec_input(profile \\ TamperProfiles.LandObs, kind, lock_jcs) do
    {_, _, kid} = infrastructure_key()
    lock = lock_input(profile)
    {seed, results} = seed_and_results(profile, kind)

    Map.merge(profile.exec_fields(kind), %{
      entropy_composition: lock.entropy_composition,
      draw_id: @draw_id,
      operator_id: @operator_id,
      operator_slug: lock.operator_slug,
      sequence: lock.sequence,
      lock_receipt_hash: sha256_hex(lock_jcs),
      entry_hash: entry_hash(),
      drand_chain: Quicknet.chain_hash(),
      drand_round: @round,
      drand_randomness: @randomness,
      drand_signature: @signature,
      wallop_core_version: lock.wallop_core_version,
      fair_pick_version: lock.fair_pick_version,
      seed: Base.encode16(seed, case: :lower),
      results: Enum.map(results, & &1.entry_id),
      executed_at: @executed_at,
      signing_key_id: kid
    })
  end

  defp seed_and_results(profile, kind) do
    {seed, _} = profile.seed(entry_hash(), @randomness, kind)
    entries = Enum.map(@entries, &%{id: &1, weight: 1})
    {seed, FairPick.draw(entries, seed, @winner_count)}
  end

  @doc """
  `profile`'s base `{lock_jcs, exec_jcs}` for one of `profile.kinds()`,
  from the real builders.
  """
  def base(profile \\ TamperProfiles.LandObs, kind) do
    lock_jcs = Protocol.build_v6_lock_payload(lock_input(profile))
    {lock_jcs, Protocol.build_v6_execution_payload(exec_input(profile, kind, lock_jcs))}
  end

  @doc """
  `profile`'s base `{lock_jcs, exec_jcs}` named `name`. Base names are
  unique within a profile's file, not across files.
  """
  def base_by_name(profile, name) do
    [kind] = for kind <- profile.kinds(), profile.base_name(kind) == name, do: kind
    base(profile, kind)
  end

  @doc """
  `profile`'s tamper cases: `{name, base, receipt, field, value, mutation,
  expected_failing_steps}`. `value` is the tampered field's new JSON value.
  """
  def cases(profile \\ TamperProfiles.LandObs), do: profile.cases()

  @doc "`profile`'s vector as a map."
  def build(profile \\ TamperProfiles.LandObs) do
    %{
      "description" => profile.description(),
      "keys" => keys(),
      "bases" =>
        for kind <- profile.kinds() do
          {lock_jcs, exec_jcs} = base(profile, kind)

          %{
            "name" => profile.base_name(kind),
            "bundle" => bundle(profile, lock_jcs, exec_jcs, kind),
            "expected_passed" => true
          }
        end,
      "cases" =>
        for {name, kind, receipt, field, value, mutation, steps} <- profile.cases() do
          %{
            "name" => name,
            "base" => profile.base_name(kind),
            "receipt" => Atom.to_string(receipt),
            "field" => field,
            "mutation" => mutation,
            "bundle" => tampered_bundle(profile, kind, receipt, field, value),
            "expected_failing_steps" => Enum.sort(steps)
          }
        end
    }
  end

  @doc "`profile`'s vector file bytes: pretty JSON with sorted keys and a trailing newline."
  def encode(profile \\ TamperProfiles.LandObs) do
    profile |> build() |> sorted() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")
  end

  defp sorted(map) when is_map(map),
    do:
      map |> Enum.sort() |> Enum.map(fn {k, v} -> {k, sorted(v)} end) |> Jason.OrderedObject.new()

  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)
  defp sorted(other), do: other

  defp keys do
    {_, op_pub, op_kid} = operator_key()
    {_, infra_pub, infra_kid} = infrastructure_key()

    [
      key_entry(op_kid, op_pub, "operator"),
      key_entry(infra_kid, infra_pub, "infrastructure")
    ]
  end

  defp key_entry(kid, public, class) do
    %{
      "key_id" => kid,
      "public_key_hex" => Base.encode16(public, case: :lower),
      "key_class" => class,
      "inserted_at" => @key_inserted_at
    }
  end

  @doc """
  `profile`'s base bundle of `kind` with one field of one receipt (or of
  both, for `:both`) replaced, re-signed.
  """
  def tampered_bundle(profile, kind, receipt, field, value) do
    {lock_jcs, exec_jcs} = base(profile, kind)

    case receipt do
      :lock ->
        lock_jcs = put_field(lock_jcs, field, value)

        exec_jcs =
          put_field(exec_jcs, "lock_receipt_hash", sha256_hex(lock_jcs))

        bundle(profile, lock_jcs, exec_jcs, kind)

      :exec ->
        bundle(profile, lock_jcs, put_field(exec_jcs, field, value), kind)

      :both ->
        lock_jcs = put_field(lock_jcs, field, value)
        exec_jcs = exec_jcs |> put_field(field, value)

        bundle(
          profile,
          lock_jcs,
          put_field(exec_jcs, "lock_receipt_hash", sha256_hex(lock_jcs)),
          kind
        )
    end
  end

  @doc """
  Decodes `jcs`, sets `field` to `value` and encodes it again as JCS.
  `{:float, n}` instead rewrites the integer `n` as `n.0` in the bytes
  themselves, since JCS would render a whole float as an integer.
  """
  def put_field(jcs, field, {:float, n}) do
    pattern = Regex.compile!(~s<"#{field}":#{n}(?=[,}])>)
    [_] = Regex.scan(pattern, jcs)
    Regex.replace(pattern, jcs, ~s<"#{field}":#{n}.0>)
  end

  def put_field(jcs, field, :reverse) do
    payload = Jason.decode!(jcs)
    Jcs.encode(%{payload | field => Enum.reverse(Map.fetch!(payload, field))})
  end

  def put_field(jcs, field, value) do
    payload = Jason.decode!(jcs)
    true = Map.has_key?(payload, field)
    Jcs.encode(%{payload | field => value})
  end

  @doc """
  The proof bundle envelope (JCS bytes) around two signed receipts, with
  `profile`'s unsigned entropy key for `kind`.
  """
  def bundle(profile, lock_jcs, exec_jcs, kind) do
    {op_sk, _, _} = operator_key()
    {infra_sk, _, _} = infrastructure_key()
    {_, results} = seed_and_results(profile, kind)

    entropy =
      Map.merge(
        %{
          "drand_round" => @round,
          "drand_randomness" => @randomness,
          "drand_signature" => @signature,
          "drand_chain_hash" => Quicknet.chain_hash()
        },
        profile.entropy(kind)
      )

    Jcs.encode(%{
      "version" => 1,
      "draw_id" => @draw_id,
      "entries" => Enum.map(@entries, &%{"uuid" => &1, "weight" => 1}),
      "results" => Enum.map(results, &%{"entry_id" => &1.entry_id, "position" => &1.position}),
      "entropy" => entropy,
      "lock_receipt" => signed(lock_jcs, op_sk),
      "execution_receipt" => signed(exec_jcs, infra_sk)
    })
  end

  defp signed(jcs, sk) do
    %{
      "payload_jcs" => jcs,
      "signature_hex" => Base.encode16(Protocol.sign_receipt(jcs, sk), case: :lower)
    }
  end

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
