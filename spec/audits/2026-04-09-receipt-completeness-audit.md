# Receipt Completeness Audit

> **Date:** 2026-04-09
> **Scope:** wallop_core 0.11.2 (post-policy-hardening, post-DB-trigger-hardening)
> **Tracking:** Invariant I-2 in [`spec/threat-model.md`](../threat-model.md)
>
> **Summary:** the lock-time receipt commits to the entry set and the
> operator's claim, but **not** to the execution output. The declared entropy
> sources, the algorithm version, the winner count, and the entropy values
> used at execution time are all uncommitted by signature. A verifier who
> only trusts signed bytes cannot independently verify any execution-path
> outcome.
>
> **Three new findings.** One is structural and arguably the largest
> remaining gap in wallop's trust story before launch.

## 1. Methodology

The question the audit answers: **for every field that determines whether a
third party will trust a published draw, does the signed receipt commit to
that field directly, indirectly (via a hash), or not at all?**

Three-step procedure:

1. **Enumerate every field that influences the pick outcome.** Start from
   `FairPick.draw(entries, seed, winner_count)` and walk backwards
   recursively. Every input to the pick — plus every input to those inputs
   — is in scope.
2. **Enumerate every field in the signed receipt payload.** Read
   `WallopCore.Protocol.build_receipt_payload/1` and
   `WallopCore.Resources.Draw.Changes.SignAndStoreReceipt`.
3. **Diff the two sets.** Anything in step 1's set that does not appear in
   step 2's set — directly, or via a hash that transitively commits to
   it — is a finding.

## 2. Fields that influence the pick outcome

Reading the codebase top-down from the execute actions and the protocol
module:

### 2.1 Direct inputs to `FairPick.draw/3`

| Input | Type | Source |
|---|---|---|
| **`entries`** | list of `{id, weight}` | `WallopCore.Entries.load_for_draw/1` (Ash query against the `entries` table, sorted by `entry_id` inside `Protocol.entry_hash/1`) |
| **`seed`** | 32-byte binary | `Protocol.compute_seed/2` (drand-only) or `Protocol.compute_seed/3` (drand + weather) |
| **`winner_count`** | integer | `draw.winner_count` (set at create time, trigger-frozen at all statuses) |

### 2.2 Inputs to `Protocol.compute_seed/3`

```elixir
json_data = %{
  "drand_randomness" => drand_randomness,
  "entry_hash" => entry_hash,
  "weather_value" => weather_value
}
jcs_string = Jcs.encode(json_data)
seed_bytes = :crypto.hash(:sha256, jcs_string)
```

| Input | Known at lock? | Source |
|---|---|---|
| **`drand_randomness`** | ❌ No (declared round's randomness is only known after the round resolves) | Fetched by `EntropyWorker` at execute time |
| **`weather_value`** | ❌ No (observation only exists after `weather_time` passes) | Fetched by `EntropyWorker` at execute time |
| **`entry_hash`** | ✅ Yes (committed at lock) | `Protocol.entry_hash/1` over the entries table |

(The drand-only `compute_seed/2` variant omits `weather_value` from the map
entirely — implicit domain separation via JCS canonicalisation.)

### 2.3 Inputs to `Protocol.entry_hash/1`

```elixir
sorted = Enum.sort_by(entries, & &1.id)
json_data = %{"entries" => Enum.map(sorted, fn e ->
  %{"id" => e.id, "weight" => e.weight}
end)}
jcs_string = Jcs.encode(json_data)
hash = :crypto.hash(:sha256, jcs_string)
```

| Input | Committed by `entry_hash`? |
|---|---|
| Each entry's `id` | ✅ Directly |
| Each entry's `weight` | ✅ Directly |
| Sort order (ascending by `id`) | ✅ Implicit in the canonical form |
| Atom-keyed input (`%{id: _, weight: _}`) | ✅ Normalised in the hash function |
| Character encoding | Relies on JCS / Elixir's default UTF-8 handling (see separate follow-up for canonical form drift) |

### 2.4 Declared entropy sources (known at lock, used later)

The `lock` action transitions a draw from `:open` through `LockDraw` and
`DeclareEntropy` to `:awaiting_entropy`. `DeclareEntropy` writes these
attributes to the draw row:

| Field | Set at | Trigger freezes |
|---|---|---|
| **`drand_chain`** | lock time | `awaiting_entropy` / `pending_entropy` |
| **`drand_round`** | lock time | `awaiting_entropy` / `pending_entropy` |
| **`weather_station`** | lock time | `awaiting_entropy` / `pending_entropy` |
| **`weather_time`** | lock time | `awaiting_entropy` / `pending_entropy` |

These are the **declared commitments** — the inputs the operator promises to
use for the eventual seed. The verifier needs them to reconstruct the seed
from the external sources (drand's published beacon, the Met Office's
published observation). Without them, the verifier cannot independently
fetch the entropy data.

### 2.5 Algorithm version

- **`fair_pick`** (external hex dep, version `~> 0.2`) — determines the
  sort/pick algorithm. Changes to `fair_pick` could silently change the
  outcome for the same `(entries, seed, winner_count)`.
- **`wallop_core`** (this repo, version 0.11.2 as of this audit) — owns
  `Protocol.entry_hash/1`, `Protocol.compute_seed/*`, the canonical
  JCS input shape, and the sorting rules.
- **JCS library version** — any change to the JCS canonicalisation could
  silently change `entry_hash` or `seed` for the same input.

These are not "fields" in the usual sense, but they are **determinants of
the outcome**: swap any of them and the same inputs produce different
winners.

### 2.6 Receipt schema version

The format of the signed receipt payload itself. Currently `@receipt_schema_version "1"`
in `WallopCore.Protocol`.

## 3. Fields in the signed receipt payload

From `Protocol.build_receipt_payload/1`:

```elixir
Jcs.encode(%{
  "commitment_hash" => commitment_hash,
  "draw_id" => draw_id,
  "entry_hash" => entry_hash,
  "locked_at" => DateTime.to_iso8601(locked_at),
  "operator_id" => operator_id,
  "operator_slug" => to_string(operator_slug),
  "schema_version" => @receipt_schema_version,
  "sequence" => sequence,
  "signing_key_id" => signing_key_id
})
```

Nine fields:

| Field | Commits to |
|---|---|
| `commitment_hash` | Same value as `entry_hash` today (historical distinction, not semantically separate) |
| `draw_id` | The draw's UUID |
| `entry_hash` | Transitively commits to the entry set + sort order (see §2.3) |
| `locked_at` | Lock time |
| `operator_id` | The operator UUID |
| `operator_slug` | The operator's canonical identity |
| `schema_version` | The receipt format version |
| `sequence` | The operator's monotonic per-draw counter |
| `signing_key_id` | Which of the operator's signing keys signed this |

## 4. The diff

| Field from §2 | In receipt? | How |
|---|---|---|
| `entries` (id, weight, sort) | ✅ | Transitively via `entry_hash` |
| `winner_count` | ❌ | **Finding A** — see §5.1 |
| `drand_chain` | ❌ | **Finding B** — see §5.2 |
| `drand_round` | ❌ | **Finding B** |
| `weather_station` | ❌ | **Finding B** |
| `weather_time` | ❌ | **Finding B** |
| `drand_randomness` | ❌ | Not knowable at lock; **Finding C** — see §5.3 |
| `weather_value` | ❌ | Not knowable at lock; **Finding C** |
| `seed` | ❌ | Derived post-lock; **Finding C** |
| `results` (winners) | ❌ | Derived post-lock; **Finding C** |
| `fair_pick` version | ❌ | **Already tracked in PAM-681** |
| `wallop_core` version | ❌ | **Already tracked in PAM-681** |
| JCS library version | ❌ | **Already tracked in PAM-681** |
| Receipt schema version | ✅ | Directly as `schema_version` |
| Entry canonical form version | ❌ | Implicit — would be pinned by `wallop_core_version` if PAM-681 lands |

## 5. Findings

### 5.1 Finding A — `winner_count` is uncommitted

**Severity:** Medium.

The `winner_count` is the single most behaviour-defining parameter after
the entry set and the seed. Change from 1 to 10 and the whole meaning of
the draw changes. It is set at create time, trigger-frozen at every status
(`IF NEW.winner_count IS DISTINCT FROM OLD.winner_count THEN RAISE`), and
**not in the receipt**.

**Exploitability today:** Very narrow. The trigger prevents any
`winner_count` change at the DB level. An attacker who could bypass the
trigger (wallop infra team with `session_replication_role = 'replica'`,
or anyone running a malicious migration) could modify `winner_count` after
the fact without invalidating the receipt — but the receipt still doesn't
cryptographically commit to the original value. The verifier has to trust
the DB row.

**Mitigation:** trigger catches it in normal operation. This is defence in
depth, not a live hole.

**Fix shape:** add `winner_count` to the signed receipt payload at lock
time. Bump `schema_version` to 2. Migrate. Filed as **PAM-697**.

### 5.2 Finding B — declared entropy sources are uncommitted

**Severity:** High.

At lock time, the `lock` action declares `drand_chain`, `drand_round`,
`weather_station`, and `weather_time` on the draw row. These are the
operator's promises about which external sources will be used for the
eventual seed. **None of them appear in the signed receipt payload.**

**Why it matters:** a verifier reading the receipt learns "this operator
locked this draw with this entry hash at this time" — but not "and
committed to use *this specific drand round* from *this specific chain*,
and *this specific weather observation time*." The verifier has to trust
the DB row for those values. The trigger prevents the row from being
modified from `awaiting_entropy` onward, so in normal operation the
declarations are stable. But the signed evidence of the declarations
doesn't exist.

**Specific attack (current state):**

1. Operator locks a draw for round R. Receipt signs `entry_hash`,
   `locked_at`, etc, but not `drand_round`.
2. Some time later, before entropy is collected, the wallop infra team
   applies a migration that bypasses the trigger via
   `session_replication_role = 'replica'` and changes `drand_round` to R'.
3. EntropyWorker fetches round R', computes the seed from R's randomness,
   executes the draw.
4. A verifier reading the receipt sees lock-time metadata and the current
   `drand_round = R'` on the row. They cannot tell whether the operator
   originally committed to R or R' — the receipt is silent.

The wallop infra team is explicitly trusted per `spec/threat-model.md` §4.5,
so this attack requires breaking an out-of-model trust assumption. But the
invariant wallop claims — "the draw's outcome was determined by external
entropy the operator committed to at lock time" — is not cryptographically
verifiable without the declarations being in the signed bytes.

**A weaker but still real attack:** if a future code path ever accepts a
different `drand_round` during execution (e.g. "retry with the next
round" logic), or if an operator with DB access could set the declarations
after seeing the round's randomness, the receipt's current contents would
not catch it.

**Fix shape:** add `drand_chain`, `drand_round`, `weather_station`, and
`weather_time` to the signed receipt payload at lock time. These are all
known at the moment `SignAndStoreReceipt` runs. Bump `schema_version` to
2 (or 3 if **Finding A** lands first). Migrate. Filed as **PAM-698**.

### 5.3 Finding C — no execution-time signed artefact

**Severity:** High. Potentially Critical depending on trust model.

This is the structural finding Colin hinted at on PAM-675:

> *"The receipt is signed at lock time, before entropy is collected, so
> the seed doesn't exist yet. That's correct in the protocol but it means
> anything that's only known post-entropy requires a second signed
> artefact (a 'proof receipt' or similar) for the verifier to anchor
> against."*

**The current state:** only one signing call site exists in the entire
codebase (`SignAndStoreReceipt` at lock time, confirmed via exhaustive
grep). After execution, the draw row contains:

- `drand_randomness` — the actual randomness from drand
- `weather_value` — the actual weather observation string
- `seed` — the derived 64-char hex seed
- `seed_json` — the canonical JSON used to derive the seed
- `results` — the winners
- `executed_at` — when execution happened

**None of these are signed by anything.** The operator's private key never
touches them. A verifier who only trusts signed bytes can confirm that
`(operator, sequence, entries, lock time)` was committed by the operator,
but cannot confirm that `(entropy, seed, winners)` was the execution
outcome the operator actually observed.

**What saves us today:**

1. **The transparency log** (daily Merkle anchor pinned to a drand round)
   commits to the *entire operator_receipts table* over time. So the
   lock-time receipts are retroactively tamper-evident. But the transparency
   log doesn't cover the *draws* table where execution output lives.
2. **The trigger** freezes `drand_*`, `weather_*`, `seed`, `results`, and
   `seed_source` via the `Cannot modify ... fields` rules and the
   terminal-state rules in `prevent_draw_mutation`. So in normal operation
   the execution output on the draw row is immutable once written.
3. **Determinism** — if the verifier has `drand_randomness`, `weather_value`,
   `entry_hash`, and the algorithm version, they can recompute the seed and
   winners independently. So they can check "given these inputs, this is
   the correct output." But they still have to trust that the *claimed*
   `drand_randomness` was the actual round's value, and that's where the
   trust model bottoms out at "drand published it, go verify with drand."

**The gap:** if a verifier only has the signed receipt (as published in
`/operator/:slug/receipts/:n`), they have no cryptographic evidence tying
it to the execution output on the public proof page. They must trust
wallop to publish the correct draws row alongside the receipt.

Compare to the layered guarantee that *would* exist:

```
Lock receipt  (signed) → commits to (entries, declarations, winner_count, ...)
Execution receipt (signed) → commits to (entropy values, seed, results, executed_at, ...)
Both receipts linked by (operator, sequence, draw_id)
```

With both, a verifier can confirm the execution outcome independent of
wallop's DB. Today they can only confirm the commitment.

**Exploitability today:**

- **By an external attacker:** blocked by the trigger.
- **By wallop-the-company (out of model per §4.5):** possible.
  wallop infrastructure could silently rewrite entries after execution —
  the trigger could be bypassed via the replica session role, and nothing
  cryptographic would catch it unless a third-party verifier happens to
  have snapshotted the execution output at the time.
- **By Postgres replication lag / split-brain:** if a future HA topology
  introduces multiple writers, the execution output could diverge between
  replicas and neither would be provably "the real one."

**Severity call:** High under the current trust model (wallop is trusted
for execution). Would be **Critical** if wallop were to claim "you don't
have to trust us for execution, either" — which is arguably what the
"provably fair" marketing implies.

**Fix shape:** add a second signed artefact at execution time — an
`ExecutionReceipt` resource, signed by the same operator key, committing
to `draw_id`, `sequence`, `entropy values`, `seed`, `results`, and
`executed_at`. Include it in the transparency log alongside the lock
receipts. Requires a new Ash resource, new table, new protocol version,
and updates to the verifier tooling. Larger change than A or B. Filed as
**PAM-699**.

### 5.4 Findings already tracked

- **PAM-681** — receipt algorithm version pinning (`wallop_core`,
  `fair_pick`, JCS versions in the payload). This audit confirms the gap
  is real and the fix shape is correct.
- **PAM-678** — canonical form drift (the entries-table refactor). This
  audit notes it as a dependency: whatever version of the canonical form
  the receipt commits to, the verifier needs an unambiguous way to
  reproduce it.

### 5.5 Non-findings (things I checked that are fine)

- **`entry_hash`** transitively commits to entry id, weight, and sort
  order. ✅ via JCS canonicalisation.
- **`sequence`** is signed and uniquely constrained. ✅
- **`operator_slug`** is signed and now also DB-trigger immutable
  (PAM-695, v0.11.2). ✅
- **`operator_id`** is signed and is a UUID FK. ✅
- **`signing_key_id`** is signed so verifiers can pick the right pubkey
  after rotation. ✅
- **The receipt's own schema version** is signed. ✅ (I was wrong about
  this earlier; correcting it here.)
- **`locked_at`** is signed as an ISO 8601 string (JCS doesn't have a
  canonical date form, but the string representation is deterministic).
  ✅
- **The transparency log** covers the receipt table via daily Merkle
  roots. ✅ This gives retroactive tamper-evidence for the lock-time
  receipts, which is why **Finding C** is "High" rather than "Critical" —
  the commitment half of the trust story is solid, it's the execution
  half that's the gap.

## 6. Recommended order for the fixes

Three new findings, three new cards:

1. **PAM-697** (Finding A, Medium): add `winner_count` to the lock-time
   receipt. Tiny change. Bump `schema_version` to 2 and add frozen vectors.
2. **PAM-698** (Finding B, High): add declared entropy sources
   (`drand_chain`, `drand_round`, `weather_station`, `weather_time`) to
   the lock-time receipt. Bump `schema_version`. Add frozen vectors.
3. **PAM-699** (Finding C, High / maybe Critical): design and implement
   an execution-time signed artefact (`ExecutionReceipt`). This is a
   protocol change of similar scope to PAM-670 — warrants a design
   document, Colin review, and an agreement on scope before implementation.

**Suggested bundling:** land A and B together in one receipt-schema-v2 bump
(they're both "add fields to the lock-time receipt"). C is a separate
protocol change and should be its own card / PR / version bump.

Once any of these land, update **Invariant I-2** in
[`spec/threat-model.md`](../threat-model.md) to remove the ⚠️ markers.

Once **PAM-654 layer 1** (frozen receipt payload vectors) lands, the
regression-prevention layer is in place and the matrix cell for I-2 goes
fully ✅.

## 7. What this audit did not cover

- **Frozen test vectors for the receipt payload bytes** — separate work,
  tracked in PAM-654 layer 1 plus a comment on PAM-654.
- **Canonical form drift between the entries table and the JCS input** —
  tracked in PAM-678.
- **A third-party audit of the cryptographic primitives themselves** —
  tracked in PAM-659.
- **The trust model around wallop-the-company** (§4.5 of the threat
  model) — out of scope for this exercise. Finding C is the one place
  this audit bumps against that assumption.

## 8. Outcome

Three new cards filed: PAM-697, PAM-698, PAM-699.

Two of them (A and B) are small schema bumps with one-day fix shapes.
One of them (C) is a protocol-level change that warrants discussion
before implementation.

Invariant I-2 in the threat model remains at ⚠️ until at least PAM-697
and PAM-698 land. PAM-699 is the path to dropping the ⚠️ on the
execution-verifiability half of the invariant, but as written the
invariant only covers *commitment* completeness — if we accept the trust
model that says "wallop is trusted for execution output," then I-2 can go
✅ once A and B land, and PAM-699 becomes a *"strengthen the trust model"*
card rather than a *"fix this gap"* card.

**That is a product decision, not a code decision, and it belongs to
Dan.**
