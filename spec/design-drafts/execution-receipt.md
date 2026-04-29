# Execution Receipt Design

> **Status:** Approved, 2026-04-09. Colin sign-off received with two
> adjustments (both incorporated below).
>
> **Implements:** Finding C from the receipt completeness audit.
> **Depends on:** lock-time receipt schema v2 (with `winner_count` and
> declared entropy sources) landing first. This design assumes lock
> receipts are already v2.

## 1. Problem

wallop_core has exactly one signing call site (`SignAndStoreReceipt` at lock
time). After execution, the draws row contains `drand_randomness`,
`weather_value`, `seed`, `results`, `executed_at` — none signed by anything.

A verifier who only trusts signed bytes can confirm the **commitment** half
of the trust story but not the **execution** half. The claim "verify without
trusting wallop" is half-true.

## 2. Design decisions (confirmed by Colin)

### 2.1 Maximalist signed surface

The execution receipt's signed payload includes every field a verifier needs
to reconstruct and verify the outcome without hitting external services:

| Field | Type | Source |
|---|---|---|
| `draw_id` | uuid | Join key to lock receipt |
| `operator_id` | uuid | Same as lock receipt |
| `operator_slug` | string | Same as lock receipt |
| `sequence` | integer | Same as lock receipt |
| `lock_receipt_hash` | string (64-char hex SHA-256) | `SHA-256(lock_receipt.payload_jcs)` — cryptographic linkage to the commitment |
| `drand_chain` | string | The chain hash used |
| `drand_round` | integer | The round number |
| `drand_randomness` | string (64-char hex) | The round's randomness |
| `drand_signature` | string | The BLS signature from drand — enables offline BLS verification |
| `weather_station` | string, nullable | Met Office station ID (null if drand-only fallback) |
| `weather_observation_time` | ISO 8601, nullable | Actual observation time |
| `weather_value` | string, nullable | Normalised reading (integer hectopascals as string) |
| `weather_fallback_reason` | string, nullable | Why weather was unavailable (if drand-only) |
| `entry_hash` | string (64-char hex SHA-256) | Redundant with lock receipt but makes seed recomputation self-contained from a single artefact (Colin review addition) |
| `wallop_core_version` | string | Version of wallop_core that ran the execution (e.g. `"0.12.0"`) |
| `fair_pick_version` | string | Version of the fair_pick dep used (e.g. `"0.2.1"`) — carried separately because `mix deps.update fair_pick` can change it without touching wallop_core |
| `seed` | string (64-char hex) | The derived seed |
| `results` | canonical JSON | Flat list of entry_id strings in position order: `["ticket-47", "ticket-12"]`. Derived from FairPick output via `Enum.map(results, & &1.entry_id)`. Position is redundant with list index — omitted. Pin in a test vector. |
| `executed_at` | ISO 8601 | When execution happened |
| `execution_schema_version` | string | Version of this payload format (starts at `"1"`) |

**Excluded from the signed payload** (per Colin):
- `weather_raw` — the raw Met Office API response. Normalisation inputs
  only; if this were signed, any Met Office response format change would
  break byte-exact verification. Keep as public auxiliary data on the
  draw row, not in the signed bytes.
- `drand_response` — same reasoning; the raw JSON from the drand API is
  auxiliary. The `drand_signature` (BLS sig) is what matters.

### 2.2 Receipt linkage: independent with `lock_receipt_hash`

The execution receipt is an **independent artefact** linked to the lock
receipt via `SHA-256(lock_receipt.payload_jcs)` in the signed payload.

Properties:
- Tampering with the lock receipt's JCS bytes invalidates the execution
  receipt's `lock_receipt_hash` → cryptographic linkage
- Each receipt is independently verifiable (different signatures, different
  keys, different schemas)
- No key rotation entanglement between operator keys and infra keys
- Survives transparency log compromise as a separate layer
- A verifier can fetch and verify either receipt without the other

### 2.3 Phase-separated keys (Colin: non-negotiable)

| Receipt type | Signed by | Rationale |
|---|---|---|
| **Lock receipt** | Operator's Ed25519 key | The operator is the actor committing to entries |
| **Execution receipt** | Wallop infrastructure Ed25519 key | wallop ran the entropy worker, fetched drand, fetched weather, computed the seed. The operator wasn't the witness. |

One wallop-wide infrastructure key. Not per-operator, not per-environment.

This makes the trust model **explicit**: the operator attests "I committed
to these entries." wallop-the-infrastructure attests "I applied this entropy
and this was the outcome." Two claims, two signers, two separate
compromise/rotation stories.

## 3. Operational decisions

### 3.1 Key storage

Same Vault (`WallopCore.Vault`, Cloak AES-GCM) as operator signing keys.
Same table shape: a new resource `WallopCore.Resources.InfrastructureSigningKey`
with `key_id`, `public_key`, `private_key` (encrypted), `valid_from`. Same
append-only pattern, same immutability trigger shape.

Upgrade to a dedicated KMS (AWS KMS, Hashicorp Vault, etc.) is future work
if an auditor or compliance requirement demands hardware-backed keys.

### 3.2 Key rotation

Manual, annual, via `mix wallop.rotate_infrastructure_key`. Inserts a new
row with `valid_from: now()`. Old key stays forever (same as operator keys).

The "current" key is the one with the largest `valid_from <= now()`.

### 3.3 Key publication

`GET /infrastructure/key` returns the current public key and `key_id`, same
response shape as `/operator/:slug/key`. Third-party verifiers need this to
verify execution receipts.

The infra public key is also included when `AnchorWorker` computes the daily
Merkle root — the anchor itself gains an infra-key signature alongside the
drand round pin. This means the transparency log becomes infra-key-signed,
closing the "who signs the log?" question.

### 3.4 Incident response (infra key compromise)

1. Rotate immediately via the mix task
2. Flag suspect execution receipts: add a `potentially_compromised_at`
   nullable timestamp column on `execution_receipts`; UPDATE all rows signed
   between last-known-good and rotation time
3. Publish an incident notice on the transparency page
4. Lock-time receipts (operator-signed) are completely unaffected

**No re-signing of affected draws** (Colin review adjustment). Re-signing
would insert a second execution receipt for the same draw, violating the
`unique_draw` identity constraint and the append-only semantics. The old
receipt is still independently verifiable under the old key — verifiers
who see the `potentially_compromised_at` flag know to treat it with
suspicion. Retroactive re-signing is a form of history rewriting that
undermines the append-only property.

Blast radius is contained: infra key compromise means "someone could forge
execution attestations" but NOT "someone could forge operator commitments."
That separation is the entire reason for phase-separated keys.

## 4. New resources and schema

### 4.1 `WallopCore.Resources.InfrastructureSigningKey`

```elixir
postgres do
  table("infrastructure_signing_keys")
end

attributes do
  uuid_primary_key(:id)
  attribute :key_id, :string, allow_nil?: false
  attribute :public_key, :binary, allow_nil?: false
  attribute :private_key, :binary, allow_nil?: false, sensitive?: true
  attribute :valid_from, :utc_datetime_usec, allow_nil?: false
  create_timestamp(:inserted_at)
end

identities do
  identity(:unique_key_id, [:key_id])
end

policies do
  policy action(:read), do: authorize_if(always())
  policy action(:create), do: forbid_if(always())
end
```

Plus an immutability trigger (same shape as `signing_key_immutability` from
the operator signing keys).

### 4.2 `WallopCore.Resources.ExecutionReceipt`

```elixir
postgres do
  table("execution_receipts")
end

attributes do
  uuid_primary_key(:id)
  attribute :draw_id, :uuid, allow_nil?: false
  attribute :operator_id, :uuid, allow_nil?: false
  attribute :sequence, :integer, allow_nil?: false
  attribute :lock_receipt_hash, :string, allow_nil?: false
  attribute :payload_jcs, :binary, allow_nil?: false
  attribute :signature, :binary, allow_nil?: false
  attribute :signing_key_id, :string, allow_nil?: false
  create_timestamp(:inserted_at)
end

identities do
  identity(:unique_draw, [:draw_id])
end

relationships do
  belongs_to :draw, WallopCore.Resources.Draw
end

policies do
  policy action(:read), do: authorize_if(always())
  policy action(:create), do: forbid_if(always())
end
```

Plus append-only trigger (reject UPDATE/DELETE).

### 4.3 Migration

Single migration that:
1. Creates `infrastructure_signing_keys` table with immutability trigger
2. Creates `execution_receipts` table with append-only trigger
3. Does NOT backfill old draws — v1 draws remain under the old trust model

### 4.4 `mix wallop.bootstrap_infrastructure_key`

One-time mix task to generate the first infra key (same pattern as
`wallop.gen.operator`). Run once at deploy time. The key is Vault-encrypted
at rest.

Separate from `wallop.rotate_infrastructure_key` which is the ongoing
rotation task.

## 5. New change module

### `WallopCore.Resources.Draw.Changes.SignAndStoreExecutionReceipt`

Mirrors `SignAndStoreReceipt` in structure:

1. Load the current infrastructure signing key (largest `valid_from <= now`)
2. Decrypt the private key via Vault
3. Load the lock receipt for this draw (to compute `lock_receipt_hash`)
4. Build the canonical payload map (§2.1 fields)
5. `Jcs.encode(payload_map)` → `payload_jcs`
6. `Protocol.sign_receipt(payload_jcs, infra_private_key)` → `signature`
7. Insert the `ExecutionReceipt` row in the same transaction
8. If anything fails, the entire execution rolls back (draw stays in
   `pending_entropy`, entropy worker retries)

Added to the end of `ExecuteWithEntropy` and `ExecuteDrandOnly` change lists.

**Critical constraint from Colin:** `results` and `seed` in the signed
payload must be the **exact canonical form from FairPick's output** with
zero intermediate Ash/Ecto transformations. Any re-serialisation between
algorithm output and signed bytes is a place where verifier re-runs can
disagree with the signed artefact. The change module receives the results
struct directly from the execute action — it must serialise to JCS from
the raw struct, not from the string-keyed `%{"position" => _, "entry_id" => _}`
map that gets written to the draw row.

## 6. Public endpoints

| Endpoint | Method | Response |
|---|---|---|
| `GET /infrastructure/key` | GET | `{key_id, public_key_hex}` |
| `GET /operator/:slug/executions` | GET | List of execution receipts for this operator |
| `GET /operator/:slug/executions/:n` | GET | Single execution receipt by sequence number |

The public proof page (`/proof/:id`) gains a second receipt section showing
the execution receipt alongside the lock receipt. v1 draws show only the
lock receipt with a note that execution attestation was not available at the
time of this draw.

## 7. Transparency log extension

`AnchorWorker` is extended:

1. The daily Merkle root now covers **both** `operator_receipts` AND
   `execution_receipts` as **separate sub-trees** (Colin review adjustment —
   pinned now, not at implementation time). The anchor's Merkle root is:

   ```
   anchor_root = SHA256(0x01 || operator_receipts_root || execution_receipts_root)
   ```

   This lets a verifier who only cares about one receipt type verify their
   sub-tree independently. The `0x01` prefix byte provides domain separation
   from leaf hashes (which use `0x00`), following RFC 6962 conventions already
   used by `Protocol.merkle_root/1`.

2. The anchor row gains an `infrastructure_signature` column — the
   Merkle root signed by the infra key. This makes the transparency log
   itself infra-key-signed.

Third-party verifiers who mirror the log over time can now check:
- Lock receipts verify under operator keys ✓
- Execution receipts verify under the infra key ✓
- The Merkle root matches the verifier's own computation ✓
- The anchor's `infrastructure_signature` verifies under the published infra key ✓

## 8. Protocol version bump

This is a **major protocol change**. Recommendation: bump `wallop_core` to
`0.12.0` (minor, since we're pre-1.0) or `1.0.0` if this is the "launch
version."

The receipt schema versions:
- Lock receipt: `schema_version: "2"` (after the lock-receipt v2 changes land)
- Execution receipt: `execution_schema_version: "1"` (new, independent)

## 9. Verification flow (what a third-party verifier does)

For a v2 draw (post-execution-receipt):

```
1. Fetch lock receipt from /operator/:slug/receipts/:n
2. Verify Ed25519(lock_receipt.payload_jcs, lock_receipt.signature,
     operator_public_key) → must be true
3. Fetch execution receipt from /operator/:slug/executions/:n
4. Verify lock_receipt_hash in execution receipt ==
     SHA-256(lock_receipt.payload_jcs) → must match
5. Verify Ed25519(execution_receipt.payload_jcs, execution_receipt.signature,
     infrastructure_public_key) → must be true
6. Parse execution receipt: extract drand_randomness, weather_value, seed
7. Recompute: Protocol.compute_seed(entry_hash, drand_randomness,
     weather_value) → must match execution_receipt.seed
8. Recompute: FairPick.draw(entries_from_lock_receipt, seed_bytes,
     winner_count_from_lock_receipt) → must match execution_receipt.results
9. (Optional) BLS-verify execution_receipt.drand_signature against the
     declared drand chain → confirms drand_randomness is authentic without
     hitting drand's HTTP API
10. Done. The draw is fully independently verified using only published keys,
     signed receipts, and deterministic recomputation.
```

For a v1 draw (pre-execution-receipt):

```
1. Fetch lock receipt from /operator/:slug/receipts/:n
2. Verify Ed25519 signature → must be true
3. Trust wallop's draws row for execution output (or independently fetch
     drand and weather from their APIs and recompute)
4. Note: v1 draws are identified by lock receipt schema_version == "1"
```

## 10. What this does NOT cover

- **Backfill:** old draws are not retroactively signed. v1 proofs remain v1.
- **Caller-seed draws:** draws executed via `Draw.execute` (caller-supplied
  seed, no entropy declaration) get an execution receipt too, but the
  payload shape is different — `drand_*` and `weather_*` fields are null,
  `seed` is the caller-supplied value. The execution receipt still attests
  "wallop ran `FairPick.draw` with this seed and this was the result."
- **SandboxDraw:** sandbox draws do not get execution receipts. They have
  no receipts at all, by design.
- **Webhook timing:** execution receipt creation must complete before the
  webhook fires, so the webhook payload can include the execution receipt
  reference.
