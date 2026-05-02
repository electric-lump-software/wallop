# Wallop Protocol Specification

Version: 0.1.0 (draft)
Date: 2026-03-24

This specification defines the deterministic draw algorithm and commit-reveal
protocol used by Wallop (provably fair random draw service). It is the single
source of truth for reimplementation in any language. An implementation is
correct if and only if it produces identical output for every published test
vector.

## Notation and conventions

- All byte sequences are written in hexadecimal unless stated otherwise.
- SHA256 refers to the hash function defined in FIPS 180-4.
- JCS refers to JSON Canonicalization Scheme, RFC 8785.
- Integers are unsigned unless stated otherwise.
- Big-endian byte order is used for all integer-to-byte conversions.
- "String" means a UTF-8 encoded byte sequence.
- Array indices are zero-based.

---

## 1. Algorithm (`fair_pick`)

### 1.1 Input

| Parameter | Type | Constraints |
|-----------|------|-------------|
| `entries` | list of `{id, weight}` | At least one entry. `id` is a non-empty string. `weight` is a positive integer. No duplicate `id` values. |
| `seed` | 32 bytes | Exactly 32 bytes. |
| `count` | positive integer | Number of winners to select. |

### 1.2 Canonicalization and pool expansion

1. **Sort** entries by `id` in ascending lexicographic byte order.
2. **Expand** each entry into `weight` consecutive copies in the pool. Each
   copy carries the original `id`.
3. The pool is a flat array of strings. For example, given entries
   `[{id: "a", weight: 2}, {id: "b", weight: 1}]`, the pool is
   `["a", "a", "b"]`.

### 1.3 PRNG

The PRNG is a counter-mode construction over SHA256.

- **State:** the 32-byte `seed` and a counter `ctr` starting at 0.
- **Block generation:** `block(ctr) = SHA256(seed || BE32(ctr))` where `BE32`
  is the 4-byte big-endian encoding of the 32-bit unsigned integer `ctr`.
- Each call to the PRNG produces one 32-byte block and increments `ctr` by 1.
- Partial blocks are never used. Each random integer consumes exactly one
  block (or more, if rejection sampling triggers).

### 1.4 Random integer in range

To generate a uniform random integer in `[0, n)` where `n > 0`:

1. Obtain the next 32-byte PRNG block.
2. Interpret the block as a 256-bit big-endian unsigned integer `v`.
3. Compute `limit = floor(2^256 / n) * n`.
4. If `v >= limit`, discard and go to step 1 (rejection sampling).
5. Return `v mod n`.

This guarantees a perfectly uniform distribution over `[0, n)`.

### 1.5 Shuffle (Durstenfeld / modern Fisher-Yates)

Let `m` be the length of the pool.

```
for i from (m - 1) downto 1:
    j = random_integer(0, i + 1)    # uniform in [0, i]
    swap pool[i] and pool[j]
```

Note: `random_integer(0, i + 1)` produces a value in `[0, i+1)` = `[0, i]`.

The full shuffle MUST be performed regardless of `count`. A partial shuffle
(only shuffling `count` positions) would consume different PRNG blocks and
produce different results. Cross-implementation compatibility requires the
complete shuffle.

### 1.6 Winner selection and deduplication

1. Walk the shuffled pool from index 0 upward.
2. Collect entry IDs, skipping any `id` already collected.
3. Stop when `count` distinct IDs have been collected, or the pool is
   exhausted.
4. If fewer than `count` distinct IDs exist in the pool, return all distinct
   IDs (no error).

### 1.7 Output

An ordered list of `{position, entry_id}` where `position` is a 1-based
integer reflecting the order of selection.

```
[
  {position: 1, entry_id: "ticket-49"},
  {position: 2, entry_id: "ticket-47"},
  {position: 3, entry_id: "ticket-48"}
]
```

---

## 2. Commit-reveal protocol

### 2.1 Entry hashing

Given a `draw_id` and a list of entries (each with a wallop-assigned
UUID and a weight):

1. Construct a JSON object:
   ```json
   {
     "draw_id": "<lowercase-hyphenated-uuidv4>",
     "entries": [
       {"uuid": "<lowercase-hyphenated-uuidv4>", "weight": N},
       ...
     ]
   }
   ```
   Entries are sorted by `uuid` ascending (lexicographic byte order).
   `weight` is a positive integer.

2. Serialize using JCS (RFC 8785).

3. `entry_hash = hex_lowercase(SHA256(jcs_bytes))`

The `entry_hash` is a 64-character lowercase hexadecimal string.

#### Durable invariant: public-derivability

**Anything this hash commits must be derivable from the public
ProofBundle bytes alone.** A third-party verifier reading the public
proof bundle MUST be able to reproduce `entry_hash` exactly, without
any authenticated operator-only data. The canonical form is strictly
`{draw_id, entries: [{uuid, weight} sorted by uuid]}`. No
operator-supplied reference data of any kind is committed; wallop
does not accept or store such data on the Entry resource.

The invariant applies to all future protocol commitments. Before
adding a field to any hashed blob, confirm the field is byte-
identically present in the public artifact a verifier consumes.

#### Validation at the boundary

A conformant producer/verifier MUST reject input that violates any
of the following, rather than silently normalising:

- `draw_id` and every entry `uuid` must be 36-character RFC 4122
  lowercase hyphenated form. No braces, no `urn:uuid:` prefix, no
  uppercase.
- `weight` must be a positive integer. Reject `0`, negative values,
  floats, and strings.

Operators who need to map wallop-assigned UUIDs back to their own
ticket or customer identifiers maintain that mapping in their own
storage. The `add_entries` HTTP response carries the newly-assigned
UUIDs as `meta.inserted_entries: [{uuid}]` in submission order, so
operators can capture the correlation without a second round trip.
The authenticated `GET /api/v1/draws/:id/entries` endpoint provides
a keyset-paginated, UUID-sorted readback at any draw status for
recovery or for canonical enumeration at lock time.

#### Binding properties

- `draw_id` is bound into the hash to prevent cross-draw confusion:
  two draws with identical entry sets produce different `entry_hash`
  values.
- `uuid` (wallop-assigned, public) and `weight` are committed. An
  operator who altered a committed `uuid` or `weight` post-lock would
  change the hash and break the signed lock receipt's signature
  verification.
- No operator-supplied reference data is ever committed or stored
  on the Entry resource. Operators who need a `(uuid → their own id)`
  mapping capture it from the `add_entries` response's
  `meta.inserted_entries` field and hold it in their own store. This
  removes an entire class of "was the stored ref tampered with?"
  concerns at the protocol layer.

### 2.2 Entropy sources

The protocol requires two independent, publicly verifiable entropy sources.
Both must be available for a draw to execute.

#### 2.2.1 drand beacon

- Source: League of Entropy (https://drand.love)
- At lock time, the API declares a future drand round number.
- After that round publishes, the `randomness` field from the drand response is
  the input. This is a 64-character lowercase hex string (32 bytes).
- The drand round, chain hash, and signature are stored for independent
  verification.

#### 2.2.2 Met Office weather observation

- Source: UK Met Office Weather DataHub, Land Observations API
- Station: **Middle Wallop, Hampshire** (Met Office station ID TBD on API
  registration). Mean sea level pressure (msl).
- At lock time, the API declares the weather station and schedules entropy
  collection for a future time (`weather_time`, the next whole hour). When the
  worker fires, it fetches the **latest available observation** from the
  declared station. The actual observation time is recorded as
  `weather_observation_time`.
- **Timing constraint:** the observation time must be strictly after the draw's
  creation time (`inserted_at`). This guarantees the reading was not yet
  published — and therefore not knowable — when entries were locked.
- The pressure reading is normalized to an **integer string** in hectopascals,
  e.g. `"1013"`, `"998"`. The raw decimal value is **rounded half-up** to the
  nearest integer (e.g. 1013.5 → `"1014"`, 1013.4 → `"1013"`).
- The station identity is not part of the protocol — it is an operational
  choice declared at lock time and stored in the proof record. The protocol
  consumes only the normalized weather value string. Changing the station does
  not affect the algorithm, only the entropy source.
- The station ID, scheduled time, actual observation time, reading type, and
  raw API response are stored for independent verification.

### 2.3 Seed computation

1. Construct a JSON object with exactly these keys:
   ```json
   {
     "drand_randomness": "<64-char lowercase hex>",
     "entry_hash": "<64-char lowercase hex>",
     "weather_value": "<normalized string>"
   }
   ```

2. Serialize using JCS (RFC 8785). Because JCS sorts keys alphabetically, the
   byte-level output is fully determined by the three values regardless of
   construction order.

3. `seed = SHA256(jcs_bytes)` — raw 32 bytes (not hex-encoded). This is the
   seed passed to the `fair_pick` algorithm.

### 2.4 Execution requirements

- A draw may only be executed after both declared entropy sources have
  published their values.
- If either entropy source is unavailable, execution MUST be refused. The
  caller may retry later.
- There is no fallback to a single entropy source or internal RNG for verified
  draws.

### 2.5 Proof record

After execution, the following are stored permanently and made publicly
available:

| Field | Description |
|-------|-------------|
| `draw_id` | Unique identifier |
| `entries` | Full entry list (as submitted) |
| `entry_hash` | As computed in §2.1 |
| `drand_round` | Declared round number |
| `drand_randomness` | Hex string from drand |
| `drand_signature` | For independent drand verification |
| `weather_station` | Station identifier |
| `weather_time` | Scheduled fetch time (next whole hour) |
| `weather_observation_time` | Actual observation time used |
| `weather_value` | Normalized string |
| `weather_raw` | Raw API response (for verification) |
| `seed_json` | The JCS-serialized JSON from §2.3 |
| `seed` | Hex-encoded 32-byte seed |
| `winner_count` | Requested number of winners |
| `results` | Ordered winner list |
| `executed_at` | UTC timestamp of execution |

The proof record is immutable after execution. No field may be modified or
deleted.

### 2.6 Signed receipts

Two signed artefacts bind the proof record to cryptographic commitments:

- **Lock receipt** — signed by the operator's `OperatorSigningKey` at
  lock time. Commits `entry_hash` (bound to `draw_id`), declared
  entropy sources, `winner_count`, `commitment_hash`, and the pinned
  algorithm identity tags enumerated below. Current schema version:
  `"4"`.
- **Execution receipt** — signed by the wallop infrastructure key at
  execution time. Links back to the lock receipt via
  `lock_receipt_hash`, commits the realised entropy values
  (`drand_randomness`, `drand_signature`, `weather_value`, …), the
  computed `seed`, the ordered `results`, the `signing_key_id`
  fingerprint of the infrastructure key that produced the signature
  (see §4.2.4 for the generic rule), and the same algorithm identity
  tags plus the drand signature scheme and the Merkle construction
  used in downstream commitments. Current schema version: `"3"`.
  Historical `"2"` receipts (produced by wallop_core 0.16.x) remain
  verifiable for the life of 1.x; see §4.3.

Both receipts are JCS-canonicalised before signing. Verifiers MUST
reject any receipt whose `schema_version` value does not match a known
shape — historical receipts remain verifiable with older verifier
versions; new receipts require current-version verifiers.

Timestamps inside signed payloads (`locked_at`, `executed_at`,
`weather_time`, `weather_observation_time`) use RFC 3339 UTC with
exactly 6 fractional digits and a literal `Z` suffix (see §4.2.1). The
producer guarantees this format; verifiers MUST reject any timestamp
that doesn't match. The `locked_at` field in a lock receipt is the
authoritative signing time against the signing key's active window
— see §4.2.4 for revocation semantics.

A separate signed artefact, the **transparency anchor**, is emitted
periodically by the wallop infrastructure key. It is NOT a field
inside any receipt; it is its own artefact with its own signature and
its own verification rules (see §4.2.6). Anchors provide a batched
commitment over the operator- and execution-receipt log and are the
mechanism by which a third party can detect silent receipt
suppression or reordering over time.

#### Pinned algorithm identity tags

The following tags are embedded verbatim in the signed payload and
covered by the Ed25519 signature. Rotating any one of them requires a
new tag value plus a schema version bump; the tag is how a verifier
decides which rules to apply.

| Tag | Value | Appears in |
|-----|-------|-----------|
| `jcs_version` | `"sha256-jcs-v1"` | Both |
| `signature_algorithm` | `"ed25519"` | Both |
| `entropy_composition` | `"drand-quicknet+openmeteo-v1"` | Both |
| `drand_signature_algorithm` | `"bls12_381_g2"` | Execution |
| `merkle_algorithm` | `"sha256-pairwise-v1"` | Execution |

#### `weather_fallback_reason` enum (execution receipt)

Accepted values: `"station_down"`, `"stale"`, `"unreachable"`, or
`null`. Free-text values are rejected. A fifth value requires a
schema version bump. Classification of raw weather-client errors
into the enum is performed by the producer before signing;
verifiers reject any value outside the four listed.

---

## 3. Test vectors

Test vectors are the definitive specification of correctness. An
implementation that produces different output for any vector is incorrect,
regardless of how reasonable its approach may seem.

Vectors are generated by the reference Elixir implementation. They are
immutable once published — if a vector and an implementation disagree, the
implementation is wrong (unless the spec itself contained an error, in which
case both the spec and vectors are updated together with a version bump).

### 3.1 Algorithm vectors

Each vector specifies:
- `entries`: list of `{id, weight}`
- `seed`: 32 bytes (hex)
- `count`: integer
- `expected_pool`: the expanded pool after canonicalization (for debugging)
- `expected_output`: list of `{position, entry_id}`

#### Vector A-1: minimal draw

```yaml
entries:
  - {id: "a", weight: 1}
  - {id: "b", weight: 1}
  - {id: "c", weight: 1}
seed: "0000000000000000000000000000000000000000000000000000000000000000"
count: 1
expected_pool: ["a", "b", "c"]
expected_output:
  - {position: 1, entry_id: "c"}
```

#### Vector A-2: weighted entries

```yaml
entries:
  - {id: "alpha", weight: 3}
  - {id: "beta", weight: 1}
  - {id: "gamma", weight: 2}
seed: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
count: 2
expected_pool: ["alpha", "alpha", "alpha", "beta", "gamma", "gamma"]
expected_output:
  - {position: 1, entry_id: "gamma"}
  - {position: 2, entry_id: "alpha"}
```

#### Vector A-3: deduplication

```yaml
entries:
  - {id: "x", weight: 5}
  - {id: "y", weight: 1}
seed: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
count: 2
expected_pool: ["x", "x", "x", "x", "x", "y"]
expected_output:
  - {position: 1, entry_id: "x"}
  - {position: 2, entry_id: "y"}
```

#### Vector A-4: count exceeds unique entries

```yaml
entries:
  - {id: "solo", weight: 3}
seed: "1111111111111111111111111111111111111111111111111111111111111111"
count: 5
expected_pool: ["solo", "solo", "solo"]
expected_output:
  - {position: 1, entry_id: "solo"}
```

#### Vector A-5: single entry

```yaml
entries:
  - {id: "only", weight: 1}
seed: "2222222222222222222222222222222222222222222222222222222222222222"
count: 1
expected_pool: ["only"]
expected_output:
  - {position: 1, entry_id: "only"}
```

### 3.2 Protocol vectors

#### Vector P-1: entry hashing

```yaml
draw_id: "11111111-1111-4111-8111-111111111111"
entries:
  - {uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", weight: 1}
  - {uuid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", weight: 2}
expected_jcs: '{"draw_id":"11111111-1111-4111-8111-111111111111","entries":[{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","weight":1},{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","weight":2}]}'
expected_entry_hash: "ca823c8814baae6a390f6f336b83584f8675aba80e0f2923963adc2511b0899c"
```

Full vector set in `spec/vectors/entry-hash.json`: single entry;
extra keys on entry maps are stripped by the reference producer
before JCS encoding — the canonical form reads only `uuid` and
`weight` (see §4.2.2); two entries sorted by uuid; weight at
2^53-1 boundary; same entries in a different draw_id produce a
different hash.

#### Vector P-2: seed computation

```yaml
drand_randomness: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
entry_hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
weather_value: "1013"
expected_seed_json: '{"drand_randomness":"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","entry_hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","weather_value":"1013"}'
expected_seed: "4c1ae3e623dd22859d869f4d0cb34d3acaf4cf7907dbb472ea690e1400bfb0d0"
```

#### Vector P-3: end-to-end

The canonical end-to-end vector lives in `spec/vectors/end-to-end.json`
and exercises the full pipeline: entries → entry_hash →
compute_seed → FairPick.draw → winners. Winners are emitted as
entry UUIDs (not the operator-supplied refs).

---

## 4. Stability contract (v1.0.0)

This section defines what a wallop_core 1.0.0 release commits to forever, and what it doesn't. If you're writing a verifier, a consumer library, or an integration test against wallop, this is the contract you can rely on.

### 4.1 Scope

The stability contract covers **the bytes that end up inside signed artefacts, the bytes a third-party verifier reads, and the algorithms that produce both**. It does not cover operational concerns, unsigned API surfaces, or storage conventions.

Any change to a frozen item after 1.0.0 is a **v2.0.0 release**. Additive changes to non-frozen surfaces ship in minor releases (1.x.0) and pass through the same review discipline that landed the 1.0.0 protocol in the first place.

**"Additive" is not carte blanche.** A new endpoint, resource, attribute, or field that introduces identity, ticketing, payment, or buyer-facing capability is out of scope regardless of whether it touches signed bytes (see §4.6). The frozen / not-frozen split is about *change mechanism*, not *scope expansion*. Reviewers approving a minor release MUST answer both questions: "does this touch frozen bytes?" (if yes — v2.0.0) and "does this expand wallop's scope beyond a fairness service?" (if yes — reject regardless of version).

**Interpretive meta-rule.** Any change that weakens a normative word in §4 — `MUST` → `SHOULD`, `MUST NOT` → `SHOULD NOT`, `required` → `recommended`, or similar — is a v2.0.0 change, not a minor release. Downgrading a conformance level in this section is a silent attack vector; it is forbidden outside a major bump.

### 4.2 Frozen at 1.0.0

The following are committed byte-level forever in the 1.x series.

#### 4.2.0 Quick reference

A third-party verifier author needs to know exactly what's frozen. The full contract follows in §4.2.1 through §4.2.7; this table is a navigation aid, not a substitute. Every item links into the normative subsection.

| Frozen surface | Subsection |
|---|---|
| Receipt schemas (lock v4 / v5; execution v2 / v3 / v4); bundle-wrapper consistency rule; closed-set key-identity fields; algorithm identity tags; `weather_fallback_reason` enum; `weather_station` charset; canonical timestamp format; `schema_version` dispatch | §4.2.1 |
| JCS canonicalisation per RFC 8785; `entry_hash` canonical form; UUID canonical form; weight type; hex normalisation; empty-draw rejection | §4.2.2 |
| SHA-256; Ed25519 (RFC 8032 §5.1); BLS12-381-G2 over the pinned drand quicknet chain hash; Merkle `sha256-pairwise-v1` construction including empty-list sentinel | §4.2.3 |
| `key_id` fingerprint rule; key-identity routing-not-security rule; revocation semantics; temporal binding to `inserted_at`; verifier mode taxonomy (Attributable / Attestable / Self-consistency only); resolver-failure-is-terminal rule; verifier-side keyring-row consistency check; signed pin file format and verifier obligations; bundled-anchor trust root for attributable mode; `/operator/:slug/keys` and `/infrastructure/keys` response shapes | §4.2.4 |
| Proof bundle byte contents at `/proof/:id.json`; bundle field-set closed-set rule; verifier hash-recomputation obligations; cross-receipt field consistency; weather observation window | §4.2.5 |
| Transparency anchor construction (`SHA-256("wallop-anchor-v1" || op_root || exec_root)`); domain-separator string; per-receipt leaf bytes with length prefix; deterministic leaf order; empty-epoch sub-root sentinel; anchor envelope JCS shape | §4.2.6 |
| Cross-draw transparency commitment at `/operator/:slug`; per-operator monotonic sequence numbers; sequence-slot immutability post-lock; lock-receipt persistence; operator slug stability | §4.2.7 |

#### 4.2.1 Receipt schemas

- **Lock receipt schema version `"5"`**. Key set and key names per §2.6 — byte-identical to v4. The bump is a coordination flag, not a payload change: a v5 receipt signals that the bundle wrapper omits the inline `operator_public_key_hex` and the verifier MUST resolve the operator key via the rules in §4.2.4 (`KeyResolver` against `/operator/:slug/keys` or an operator-published `.well-known` pin). The historical v4 shape — same field set, with inline `operator_public_key_hex` on the bundle wrapper — remains verifiable for the life of 1.x per §4.4.
- **Execution receipt schema version `"4"`**. Key set and key names per §2.6 — byte-identical to v3. Mirrors lock v5: a v4 execution receipt signals that the bundle wrapper omits the inline `infrastructure_public_key_hex` and the verifier MUST resolve the infrastructure key via §4.2.4. The v3 shape is v2 plus the `signing_key_id` field identifying the wallop infrastructure signing key. v0.16.x-era v2 receipts and v0.17.x-era v3 receipts remain verifiable for the life of 1.x per §4.4; conforming verifiers MUST dispatch on `schema_version` first per §4.2.1 "older-schema rejection."
- **Bundle-wrapper / receipt-version consistency rule.** The bundle's `lock_receipt` and `execution_receipt` wrapper objects carry an inline `operator_public_key_hex` / `infrastructure_public_key_hex` only for receipt schemas that legacy-encode key identity inline (lock v4; execution v2 / v3). For lock v5 and execution v4 the wrapper MUST omit the inline key. A bundle whose receipt schema and wrapper shape disagree MUST reject as a downgrade-relabel attempt (v5 with inline key) or upgrade-spoof attempt (v4 / v3 / v2 missing inline key). Mirrors the v2 / v3 deny_unknown_fields defence one level out: producers cannot relabel one schema as another to elide or smuggle a field.
- **Key-identity fields on receipts are closed-set.** The `signing_key_id` field is the sole permitted key-identity field on any wallop-produced signed receipt or anchor envelope. Fields describing key version, algorithm, issuance time, expiry, custodian, or provenance are out of scope for wallop_core and MUST NOT be added in 1.x. Key metadata beyond identity belongs in the published keyring artefact, not on individual receipts. Any proposal to add such a field is a v2.0.0 discussion.
- **Anti-forgery binding vs identity disambiguation.** `lock_receipt_hash` on the execution receipt is the anti-forgery binding — it cryptographically commits the execution to the specific lock receipt signed by the operator, so an attacker cannot substitute an execution receipt onto a different lock without holding the operator key. `signing_key_id` is identity disambiguation — it tells the verifier which infrastructure public key to resolve from the keyring, closing the "try all historical keys" brute-force path after a rotation. Neither prevents compromise of a key an attacker already controls; together they localise any future key compromise to receipts signed after the compromise, without re-opening any pre-compromise receipt.
- **Algorithm identity tags** inside every signed receipt (§2.6):
  - `jcs_version: "sha256-jcs-v1"`
  - `signature_algorithm: "ed25519"`
  - `entropy_composition: "drand-quicknet+openmeteo-v1"`
  - `drand_signature_algorithm: "bls12_381_g2"` (execution receipt only)
  - `merkle_algorithm: "sha256-pairwise-v1"` (execution receipt only)
- **`weather_fallback_reason` enum** values: `"station_down"`, `"stale"`, `"unreachable"`, or `null`. The key MUST always be present on execution receipts; omission vs explicit `null` is a parity bug. Any other value rejects.
- **`weather_station` charset**: `^[a-z0-9][a-z0-9_-]*[a-z0-9]$` — lowercase ASCII alphanumeric with internal hyphens or underscores allowed, no leading/trailing separator, minimum 2 characters, maximum 32. The 32-byte cap is deliberately tight: weather station identifiers in every sensible naming scheme (NOAA, METAR, MADIS, Met Office) fit comfortably, while the cap shuts the door on a bad-actor fork smuggling hashed identity data through an unconstrained free string. Conforming verifiers MUST reject receipts with non-matching `weather_station` values. Current production value: `"middle-wallop"`.
- **Timestamp format** for every timestamp field in a signed payload (`locked_at`, `executed_at`, `weather_time`, `weather_observation_time`): RFC 3339 UTC, exactly 6 fractional digits, explicit `Z` suffix (never `+00:00`), matching the regex `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$` (anchored to the full string; no `^`/`$` multiline flag, equivalent to Rust `\A...\z`). This regex is the normative ingest acceptance test; conforming verifiers MUST gate on it *before* handing the string to a general-purpose RFC 3339 parser. Implementations MUST pad to 6 digits when the source has fewer and MUST reject any timestamp whose serialised form does not match the regex. Example: `"2026-04-23T14:22:17.123456Z"`. **Note (informative, as of 2026):** general-purpose RFC 3339 parsers (historically including Rust `chrono::DateTime::parse_from_rfc3339` and `time::OffsetDateTime`) accept variable fractional-digit counts and `+00:00` offsets and would silently admit non-canonical forms if not gated by the regex above.
- **Verifiers MUST read `schema_version` first and dispatch on it.** Field-shape heuristics are not a substitute. A naive verifier that accepts any receipt whose fields look familiar will accept a future v5 (or v3 execution) receipt whose superset is a superset — that is a vulnerability, not a feature.
- **Older-schema rejection and dual-version support.** A verifier pinned to a single execution schema MUST reject receipts with any OTHER `schema_version` with the same clarity as unknown-future values. A verifier MAY simultaneously support BOTH `"2"` and `"3"` execution receipts for the life of 1.x (`wallop_verifier` ≥ 0.9.0 does this — see §4.5); in that case each version MUST be parsed under its own exact-field-set schema (no shared "loose" parser), and a payload whose declared `schema_version` does not match its actual field set MUST reject. In concrete terms: a v3 payload with `signing_key_id` stripped and relabelled as `"2"` fails the v2 parser's exact-field-set check; a v2 payload relabelled as `"3"` fails the v3 parser's "`signing_key_id` is required" check. Verifiers that silently accept older receipts by pattern-matching on familiar fields enable downgrade attacks.

#### 4.2.2 Canonical forms

- **JCS canonicalisation** per RFC 8785 — the serialisation applied before every hash and signature.
- **`entry_hash` canonical form**: `SHA-256(JCS({draw_id, entries: [{uuid, weight} sorted by uuid]}))` (§2.1). The `entries[*]` objects contain exactly two fields — `uuid` and `weight`. Conforming **producers** MUST strip any additional keys before JCS encoding; only `uuid` and `weight` reach the encoder. Whether a producer additionally rejects input with extras is a local hardening choice and is not part of the wire contract. The wire contract is strictly about the bytes reaching JCS.
- **UUID canonical form**: 36 characters, lowercase, hyphenated, RFC 4122 v4. Uppercase / braced / `urn:uuid:`-prefixed forms MUST reject at every ingest and validation point.
- **Weight type**: positive integer. Canonical JSON MUST serialise as a JCS number per RFC 8785 §3.2.2.3 — no leading `+`, no leading zeros, no trailing `.0`, no exponent for integers ≤ 2^53-1. Floats, strings, `null`, negative values, and zero MUST reject. The current operational ingest cap (`weight ≤ 1000`) is behavioural, not protocol — see §4.3.
- **Entry list size**: operational hard cap of 10,000 entries per draw at the `add_entries` layer. See §4.3 — this is a behavioural limit, not a protocol limit. Implementations MUST handle arbitrary-length entry lists for verification purposes even if they enforce a smaller cap at ingest.

- **`drand_randomness` normalisation**: lowercase 64-character hex, no `0x` prefix, no whitespace. The same rule applies to any `drand_signature` / `entry_hash` / `seed` / `commitment_hash` field serialised as hex in a signed payload — lowercase hex, no prefix, no whitespace, exact expected byte length.
- **Empty-draw behaviour**: `entry_hash` over an empty entry list is undefined. Construction rejects.

#### 4.2.3 Cryptographic primitives

- **SHA-256** for every digest produced by wallop_core. (Internal hashing inside other primitives — e.g. BLS12_381_G2's own hash-to-curve — is defined by those primitives' specs, not this one.)
- **Ed25519** raw signatures as defined by RFC 8032 §5.1 (not Ed25519ph / pre-hashed; no pre-hashing step applied before signing).
- **drand quicknet** beacon verification: `BLS12_381_G2` signature suite over the chain hash pinned in `WallopCore.Drand.Config`.
  - **The chain-hash pin is frozen.** A post-1.0.0 change of which drand chain wallop consumes is a v2.0.0.
  - **Upstream key-period transitions within the same chain** are verified by the chain's own rules and do not affect wallop's pin; historical receipts against prior key periods remain verifiable.
- **Merkle construction `sha256-pairwise-v1`**:
  - `leaf_hash(bytes) = SHA-256(0x00 || bytes)` — single-byte `0x00` domain prefix; concatenation is byte-level with no length prefix.
  - `node_hash(L, R) = SHA-256(0x01 || L || R)` — single-byte `0x01` domain prefix; concatenation is byte-level with no length prefix.
  - Odd-level rule: duplicate the final node (Bitcoin-style). No sentinel padding.
  - **Empty leaf list**: the Merkle root is `SHA-256(<<>>)` — the 32-byte digest of the empty byte string, with no `0x00` leaf-prefix applied. The leaf-hash rule is skipped entirely in the empty case. (This is the sentinel used by `transparency_anchors` for a draw whose winner list is empty; it is NOT the same as `leaf_hash(<<>>) = SHA-256(<<0x00>>)`, which would be a different 32 bytes.)

#### 4.2.4 Key identity

The rules in this subsection apply to every key whose signatures are verified by a wallop verifier — operator signing keys (covered by the operator keyring) and wallop-held infrastructure signing keys (used for execution receipts and transparency anchors) alike. The fingerprint mechanics, resolution rules, and revocation semantics are identical across both classes; keyring location differs but the wire contract does not. **Hex strings throughout this subsection are lowercase a-f only; verifiers MUST reject any value containing mixed-case or upper-case hex characters.**

- **`key_id` fingerprint**: first 4 bytes of `SHA-256(public_key)`, hex-encoded lowercase (8 characters). Appears in signed receipts and in the keyring exposed at `GET /operator/:slug/keys`.
- **`key_id` is a display / routing hint, NOT a security identifier.** With a 32-bit fingerprint, birthday collisions become non-negligible at keyring sizes above a few tens of thousands of keys per operator. Verifiers MUST resolve the full public key from the operator keyring (indexed on the `(operator_id, key_id)` pair; the keyring handles any collision at that resolution step) and then verify the Ed25519 signature against the full public key. Never trust a signature because its `key_id` matches a known-good one.
- **Unresolvable `key_id`**: if a verifier encounters a receipt whose `key_id` is not present in the operator's keyring, the receipt MUST reject. No "try all known keys," no "assume rotation we can't prove" — reject with a clear error.
- **Revocation semantics**: `revoked_at` is forward-only. A signature created before `revoked_at` remains permanently valid; a signature dated after `revoked_at` MUST reject. Verifier uses the per-receipt-class binding timestamp (`locked_at` for lock receipts, `executed_at` for execution receipts, `anchored_at` for transparency anchors — defined in the temporal-binding rule below) against the key's active window. Pre-revocation signatures remain permanent history; revocation is a forward-only gate.
- **Temporal binding to first-existence timestamp.** Every signed artefact is bound to the moment the signing key first appeared in the keyring. Each receipt class is checked against its own binding timestamp:
  - **Lock receipt:** verifier MUST reject unless `operator_signing_key.inserted_at <= lock.locked_at`.
  - **Execution receipt:** verifier MUST reject unless `infrastructure_signing_key.inserted_at <= execution.executed_at`.
  - **Transparency anchor:** verifier MUST reject unless `infrastructure_signing_key.inserted_at <= anchor.anchored_at`.

  The `inserted_at` value is the keyring entry's first-existence timestamp — the append-time committed by the keyring's storage layer. It is deliberately not "the latest valid key as of the binding timestamp"; closing that remaining gap would require committing a rotation log and is out of scope for 1.x (goal 2). The verifier-side comparison has **no skew tolerance**: both timestamps in the comparison are operator-produced and committed, so any drift is signal, not noise. This rule composes with the closed-set identity-field rule above (no new key-identity fields are needed; the binding rides on existing keyring metadata) and with the keyring retention obligation in §4.4 (a keyring missing the row that anchored a historical receipt is indistinguishable from tampering, and the verifier MUST reject in both cases).

  *Operational note (storage-side enforcement).* Producers MUST enforce that `valid_from` and `inserted_at` agree at row-write time, with a tolerance no greater than 60 seconds in either direction. This is a producer-side hardening rule; it bounds clock-skew exposure between the application and the database without affecting the verifier-side comparison above. The reference implementation enforces this via a `CHECK` constraint on each keyring table.

- **Verifier mode taxonomy.** A verifier reports the trust model it operated under. Three modes exist:

  | Mode | Trust root | What it proves |
  |---|---|---|
  | **Attributable** | Wallop infrastructure-key fingerprint compiled into the verifier the user is running (or supplied out-of-band via a verifier-side anchor flag); the trust root is therefore the verifier binary's supply chain, not any URL fetched at verify time | The keys listed in this draw's keyring were published by wallop's infrastructure under a signing key whose fingerprint the verifier user has committed to accepting, and the live keyring is a subset of that commitment |
  | **Attestable** | wallop's `/operator/:slug/keys` endpoint, no pin | The wallop endpoint says these keys signed; same-origin caveat — a CDN compromise can serve coherent forgeries |
  | **Self-consistency only** | Bundle-embedded inline keys (legacy v3 / v4 receipts only) | The bundle is internally consistent; says nothing about who produced it |

  Mode names are load-bearing: attestable is "the endpoint says so," not "attributable." Only attributable mode binds the verification to an out-of-band identity. Verifiers MUST surface the active mode in their report (CLI header, JSON top-level field, browser-side proof page UX). A verification that does not name its mode is non-conformant.

- **Resolver failure is terminal.** When a verifier cannot resolve a `key_id` against its configured trust root — endpoint unreachable, key not in keyring, pin mismatch, malformed response, internal inconsistency — the receipt MUST reject. Verifiers MUST NOT fall back to inline receipt-block keys when resolution fails.

- **Verifier-side keyring-row consistency check.** After resolving a `key_id` against a trust root, the verifier MUST compute `key_id` locally from the resolved `public_key` (per the fingerprint rule above) and reject if it does not match the requested `key_id`. This is the verifier-side mirror of the producer's keyring-row consistency assertion at sign time; a buggy or hostile resolver answering for a request for `key_id=X` with a different key would otherwise pass the signature step against the wrong key.

- **Pin file format (`.well-known/wallop-keyring-pin.json` and `GET /operator/:slug/keyring-pin.json`).** The keyring pin used by attributable mode is **signed by the wallop infrastructure key**. An unsigned pin would sit in the same trust domain as the live `/operator/:slug/keys` endpoint and add no cryptographic substance over attestable mode; the wallop infrastructure signature is what makes the pin a cacheable, mirrorable cryptographic commitment that does not require TLS to the operator's domain at verify time.

  ```json
  {
    "schema_version": "1",
    "operator_slug": "...",
    "keys": [
      { "key_id": "...", "public_key_hex": "...", "key_class": "operator" }
    ],
    "published_at": "2026-04-26T12:34:56.789012Z",
    "infrastructure_signature": "..."
  }
  ```

  - **`schema_version` is the literal string `"1"`** — verifiers MUST reject any other value with the same exact-match discipline applied to the keys-list endpoint above.
  - **`keys[]` MUST be sorted by `key_id` ascending at sign time and MUST be non-empty.** Sort is **byte-order ascending (equivalently: lexicographic on ASCII)** — verifiers and producers in locale-sensitive environments MUST NOT use locale-aware string comparison. Each row contains exactly `key_id`, `public_key_hex`, and `key_class`; **every row's `key_class` MUST be the literal string `"operator"`** (compared as byte-equal ASCII; no Unicode normalisation, no `o...` escape smuggling) — infrastructure keys are not committed in the pin (they are anchored separately via the trusted-anchor set; see "Bundled-anchor trust root" below). Any other `key_class` value, or an empty `keys[]`, is `PinSchemaMismatch`. `inserted_at` is deliberately absent from the pin (it lives on the live keys-list endpoint per the temporal-binding rule above and would be redundant on the pin).
  - **`published_at` semantics.** The producer MUST set `published_at` to its own wall-clock UTC timestamp (in the canonical timestamp format defined elsewhere in this section) immediately before computing the signature pre-image. The field MUST NOT be re-stamped on cache hits or replayed from a stored value; if a stored or cached `published_at` is more than 60 seconds older than `now` at sign time, the producer MUST refresh `published_at` and re-sign before serving.
  - **`infrastructure_signature`** is an Ed25519 signature over the JCS canonicalisation of `{schema_version, operator_slug, keys[], published_at}` (the `infrastructure_signature` field itself is excluded from the pre-image), with the byte-prefix `"wallop-pin-v1\n"` (14 ASCII bytes including the trailing line feed: `0x77 0x61 0x6c 0x6c 0x6f 0x70 0x2d 0x70 0x69 0x6e 0x2d 0x76 0x31 0x0a`) prepended to the canonical bytes before signing. The prefix is a frozen domain separator that prevents a pin signature from being replayable against any other signed wallop artefact. No other wallop signed artefact uses the prefix `wallop-pin-`, and any future signed payload type added in 1.x MUST select a domain separator outside that namespace. **Wire format**: lowercase 128-character hex, no prefix or whitespace, encoding the 64-byte raw Ed25519 signature per RFC 8032 §5.1.
  - **Verifier pre-image reconstruction.** A verifier reconstructs the signed pre-image by parsing the pin JSON, removing the `infrastructure_signature` member from the parsed object, JCS-canonicalising the remainder, and prepending the domain-separator byte sequence above. The `infrastructure_signature` field MUST be removed entirely before re-canonicalising; an absent member produces a different JCS canonical byte sequence than a member set to `null`, and the producer signs over the absent-member form. **Verifiers MUST NOT re-sort `keys[]` before pre-image reconstruction**: JCS (RFC 8785) does not reorder array elements, the signature commits to the producer-supplied order, and array ordering is enforced as structural validation at verifier obligation 1 below — an unsorted array MUST fail with `PinSchemaMismatch` before any signature work, never silently re-sorted into compliance.
  - **Producer obligations.** wallop_core MUST NOT sign a pin with an infrastructure key whose `revoked_at` is set, regardless of whether the key remains in any verifier's bundled anchor grace window. The verifier-side temporal-binding check (verifier obligation 4 below) rejects such pins as defence-in-depth; the primary defence is the producer not signing them in the first place.
  - **Verifier obligations.** A verifier in attributable mode MUST:
    1. Validate the pin envelope structurally before any signature work: `schema_version` exact-match, `keys[]` ordering, timestamp regex on `published_at`. Failure is `PinSchemaMismatch`.
    2. Apply the freshness rule below.
    3. Verify `infrastructure_signature` against an anchor in its trusted-anchor set (see "Bundled-anchor trust root" below). Failure to find a verifying anchor is `AnchorNotFound`.
    4. Apply temporal binding to the verifying anchor: the anchor's `inserted_at` and `revoked_at` (or unset) MUST contain `pin.published_at`. Out-of-window → `PinSignatureInvalid` (the anchor was not authorised to sign at that moment).
    5. Verify `pin.operator_slug == bundle.operator_slug` (`PinSchemaMismatch` on mismatch).
    6. Resolve the requested `key_id` via the live `/operator/:slug/keys` endpoint (delegated to attestable-mode resolution). The same-origin caveat that applies to attestable mode here is closed by step 8 below: the live response is cross-checked against the signed pin snapshot, so a tampered live endpoint that returns a key not in the pin fails `PinMismatch` instead of being accepted.
    7. Apply `key_class` cross-role discipline: an `operator`-class entry MUST NOT be used to verify an `infrastructure`-class signature, and vice versa (`PinSchemaMismatch`).
    8. Assert that the resolved `(key_id, public_key_hex)` tuple is present in `pin.keys[]`. Strict per-resolution equality; **no forward-compat tolerance** for keys the pin does not list. `PinMismatch` on absence.
  - **Pin freshness.** `published_at` is parsed under the canonical timestamp rule defined elsewhere in this section (RFC 3339 UTC, microsecond precision, exact regex match — same rule applied to every signed timestamp in this spec). Verifiers MUST reject a pin whose `published_at` is greater than the verifier's clock plus 60 seconds (clock-skew tolerance). Distinct error variant: `PinPublishedInFuture`. Verifiers MUST accept, but SHOULD emit a warning for, a pin whose `published_at` is more than 24 hours before the verifier's clock; the warning is suppressed by an explicit verifier-side opt-out (e.g. `--no-stale-warn`). Both thresholds are documented constants and are not configurable on the wire.

- **Bundled-anchor trust root for attributable mode.** A verifier in attributable mode MUST hold an out-of-band trust anchor for wallop's infrastructure signing key(s); without one it MUST refuse `--mode attributable` and exit non-zero, never silently downgrading to attestable. The reference verifier embeds the current trusted-anchor set at compile time in a code-committed, OSS-auditable artefact (see `wallop_verifier/src/anchors.rs`). Verifier users MAY override the bundled set via a CLI flag (the reference verifier exposes `--infra-key-pin`, repeatable); the override **replaces** the bundled set, never extends it. Live `/infrastructure/keys` payloads MUST NOT be consulted to verify the pin's signature; the live endpoint exists to discover candidate `key_id`s for receipt verification, which is then re-anchored via the pin.

  - **Anchor record shape.** Each bundled anchor entry MUST carry exactly: `key_id` (8-character lowercase hex per the fingerprint rule above), `public_key_hex` (64-character lowercase hex), `inserted_at` (RFC 3339 UTC microsecond per the timestamp rule above), and `revoked_at` (same format, or absent for currently-active anchors). The temporal-window check in verifier obligation 4 above operates on these fields: pin verifies if `anchor.inserted_at <= pin.published_at`, and (`anchor.revoked_at` is absent OR `pin.published_at < anchor.revoked_at`). A bundled anchor missing any required field is a verifier-construction error; the verifier MUST refuse `--mode attributable` rather than treat the field as absent.
  - **Infrastructure-class signature resolution.** In attributable mode, every `infrastructure`-class signature the verifier checks (execution receipts, transparency anchors, and the pin itself) MUST resolve its `key_id` against the trusted-anchor set, never against the live `/infrastructure/keys` endpoint. The live endpoint MAY be consulted to enumerate candidate infrastructure `key_id`s, but the `(key_id, public_key_hex)` tuple used for signature verification MUST come from a bundled or `--infra-key-pin`-supplied anchor record, with the temporal-binding check in verifier obligation 4 applied against `executed_at` / `anchored_at` / `published_at` as appropriate. A `key_id` not present in the trusted-anchor set is `AnchorNotFound`; falling back to the live endpoint for infrastructure keys is non-conformant.
  - **Override carries a full record.** The `--infra-key-pin` override MUST supply a complete anchor record (`key_id`, `public_key_hex`, `inserted_at`, and `revoked_at` or its absence) so the temporal-binding rule in verifier obligation 4 applies uniformly to bundled and overridden anchors. A verifier exposing the override as a CLI flag chooses its own input form (single argument, JSON file, multiple flags); the requirement is on the underlying record shape, not the surface. A verifier MUST NOT accept a hex-only public key without the surrounding metadata — the temporal-binding check is load-bearing and the override path cannot bypass it.
  - **Anchor-publication discipline (producer).** wallop_core MUST publish the full anchor record (`key_id`, `public_key_hex`, `inserted_at`, and `revoked_at` once set) for every infrastructure key insertion to a stable, append-only public location at the time the key first signs anything. The bundled anchor set in released `wallop_verifier` crate versions is a convenience layer over this canonical record; verifier users with a need to verify pins signed during a release pause obtain the anchor record from the canonical publication and supply it via `--infra-key-pin`. The publication is the source of truth; the crate is a snapshot.
  - **Anchor-set cadence.** The bundled set holds at most two entries: the current wallop infrastructure key plus at most one previous key retained for a 90-day grace window post-rotation. After the grace window elapses, the previous anchor is removed in the next verifier crate release.
  - **Compromise.** A wallop infrastructure key discovered to be compromised is removed **immediately** from the bundled set in a new verifier crate release; pins it signed become unverifiable in the new crate. There is no "previously-signed pins remain valid" carve-out for compromise: a verifier cannot distinguish honest pre-compromise signatures from forged ones once the key material is in adversary hands.
  - **Production-only by definition; greenfield handling.** Tier-1 attributable mode applies to bundles produced by a wallop deployment whose infrastructure key is in the released bundled anchor set. Sandbox, staging, development, and any other non-production deployments use independent infrastructure keys not committed to in any released `wallop_verifier` crate; verification of their bundles operates in attestable mode against the deployment's own keys-list endpoint. A wallop deployment that has not yet generated and anchored its first infrastructure key (greenfield) is similarly outside attributable mode. In both cases `--mode attributable` MUST return `AnchorNotFound` deterministically rather than silently falling back to attestable.

- **`/operator/:slug/keys` response shape.** Same shape consumed by attestable and attributable modes:

  ```json
  {
    "schema_version": "1",
    "keys": [
      {
        "key_id": "...",
        "public_key_hex": "...",
        "inserted_at": "2026-04-26T12:34:56.789012Z",
        "key_class": "operator"
      }
    ]
  }
  ```

  Same shape applies to the infrastructure-key endpoint at `GET /infrastructure/keys`. `inserted_at` is load-bearing for the temporal-binding rule above; `key_class` discriminates operator from infrastructure keys.

  **The envelope is closed-set under `schema_version: "1"`.** The response object MUST contain exactly the top-level members `schema_version` and `keys`, and no others. Each row in `keys` MUST contain exactly `key_id`, `public_key_hex`, `inserted_at`, and `key_class`, and no others. A future producer that wants to add a field MUST bump `schema_version` to a new exact value; conforming verifiers will reject the new shape until updated. This composes with the row-level closed-set discipline applied to receipts in §4.2.1.

  **`schema_version` is a JSON string with exact-match semantics.** Verifiers MUST reject any keys-list response whose top-level `schema_version` is anything other than the literal string `"1"` — no semver coercion, no prefix matching, no numeric comparison, no implicit forward compatibility. A future shape bump is a coordinated wallop_verifier release; the new value is a different exact match. This is the same closed-set rule applied to receipt `schema_version` in §4.2.1.

  **Producer-side state is not on the wire.** The keyring holds a `valid_from` field (the producer's signing-eligibility timestamp, held within ±60 seconds of `inserted_at` by a CHECK constraint). It is deliberately omitted from the response shape: emitting it would invite resolver implementations to compare it against the receipt's binding timestamp instead of `inserted_at`, reopening the temporal-binding window. The four fields above are the canonical pin row.
- **CLI-without-keyring caveat (attributable authenticity vs self-consistency).** A verifier that validates a bundle against keys **embedded in the bundle itself** — without independently resolving those keys from the operator keyring at `GET /operator/:slug/keys` (or from a locally-pinned trust root supplied out of band) — provides *self-consistency* only, not attributable authenticity. The bundle's signatures being valid under its embedded keys does not rule out substitution of both the bytes and the keys by a MITM or tampered mirror: an attacker serving a forged bundle can sign it with their own keypair and embed that keypair's public half, and every step of the verification pipeline will pass. Attributable authenticity requires an out-of-band binding between operator identity and the public key being verified against. Verifiers intended for third-party attribution (dashboards, publishing pipelines, audit tooling) MUST resolve keys from the operator keyring endpoint or a pinned trust root and MUST NOT silently fall back to bundle-embedded keys when that resolution fails.

#### 4.2.5 Public artefacts

- **Proof bundle byte contents** served at `/proof/:id.json` — the JSON shape third-party verifiers consume. The proof bundle schema is a **closed set**: the field set is frozen for 1.x. A conforming producer MUST NOT emit unknown fields; a conforming verifier MUST ignore unknown fields it encounters (defensive against tampered or impostor bundles).
- **Any addition to the signed-byte shape is a v2.0.0**, not a minor release. A unsigned envelope field addition is also a closed-set violation under the rule above; do not confuse "not signed" with "safe to add."
- **Verifier obligation beyond unknown-field ignorance.** "Ignore unknown fields" does NOT extend to ignoring unknown entries in a signed list. Verifiers MUST recompute every hash committed in the bundle and compare each against the signed receipt's committed value. The full list:
  - `entry_hash` from the entries array (§2.1)
  - `seed` from the declared entropy inputs (§2.3)
  - fair_pick winners from the seed and entries (§1)
  - `lock_receipt_hash` in the execution receipt — recompute `SHA-256` of the lock receipt's canonical payload bytes and compare; this binding is what prevents an execution receipt from being substituted onto a different lock receipt.
  Any mismatch MUST reject. A bundle with extra entries whose `entry_hash` still matches would require a second preimage on SHA-256 — mathematically infeasible; a bundle with extra entries whose `entry_hash` does not match must reject.
- **Cross-receipt field consistency.** Every field that appears in both the lock receipt and the execution receipt with the same name and the same intended value MUST be byte-identical across the two receipts; the verifier MUST reject a bundle on any mismatch. Without this check, an infra-level attacker signing a fraudulent execution receipt can pair it with a legitimate lock receipt from a different draw (or a different operator, or a different entropy window) — `lock_receipt_hash` alone binds the lock bytes into the exec but does not bind the exec's own duplicated fields back to the lock. The fields subject to this rule, as of this spec revision, are: **`draw_id`**, **`operator_id`**, **`sequence`**, **`drand_chain`**, **`drand_round`**, and **`weather_station`**. The bundle envelope's `draw_id` MUST also match both receipts' `draw_id`. Fields intentionally excluded are `signing_key_id` (different keys by design — the operator's on the lock receipt, the wallop infrastructure's on the execution receipt) and `operator_slug` (derivative of `operator_id`). Algorithm identity tags (`jcs_version`, `signature_algorithm`, `entropy_composition`, `drand_signature_algorithm`, `merkle_algorithm`) are already validated per-receipt against pinned values in §4.2.1 and §2.6 and do not need a separate cross-check.
- **Weather observation window.** The execution receipt's `weather_observation_time` MUST fall in the interval `[lock.weather_time - 3600s, lock.weather_time]` inclusive. Verifiers MUST reject on violation. The bound direction reflects production behaviour: Met Office publishes observations at hour boundaries (`XX:00:00` UTC), and the entropy worker fetches the most recent observation at or before the declared target, so `exec.weather_observation_time` is typically earlier than `lock.weather_time` by up to an hour. This check prevents an infrastructure-level attacker from fetching weather from any point in time and retroactively attributing it to the draw's declared window, which would otherwise allow the entropy-retry manipulation described as a residual trust assumption in §4.4.
- **Top-level JSON key order** in `/proof/:id.json` SHOULD match JCS-canonical order (lexicographic on keys) for ease of byte-comparison. This is a presentation recommendation on the outer envelope; the inner signed payloads MUST be JCS-canonical. Outer-envelope key-order drift is not a signature-verification failure — only the inner JCS bytes are signed.
- **Endpoint location.** The proof bundle is fetchable at `/proof/:id.json` without authentication. Verification is a public operation.

#### 4.2.6 Transparency anchors (separate artefact)

The `transparency_anchors` table holds periodic epoch anchors — a batched Merkle commitment over all operator and execution receipts in an epoch, signed by the wallop infrastructure key. It is NOT a field inside any receipt; it is a separate public artefact with its own lifecycle and signature.

- **Epoch definition.** An epoch is a wall-clock window whose boundaries are pinned at deployment time (configurable via `:wallop_core, :transparency_anchor_epoch`). The current production value is 1 hour, boundaries aligned to UTC clock hours. An anchor is emitted for every epoch in which at least one operator receipt OR at least one execution receipt was signed. The epoch boundaries are NOT part of the 1.x protocol freeze — operators may run shorter or longer epochs by configuration — but `epoch_start` and `epoch_end` timestamps appear in the anchor envelope (below) so third-party auditors can verify cadence.
- **Anchor root construction.** `anchor_root = SHA-256("wallop-anchor-v1" || op_root || exec_root)`, where `op_root` and `exec_root` are per-epoch Merkle roots computed under §4.2.3's `sha256-pairwise-v1` rules over the epoch's operator and execution receipts respectively.
- **Prefix string `"wallop-anchor-v1"`** is encoded as 16 ASCII bytes — specifically `0x77 0x61 0x6c 0x6c 0x6f 0x70 0x2d 0x61 0x6e 0x63 0x68 0x6f 0x72 0x2d 0x76 0x31`. Frozen domain separator; rotating it is a v2.0.0.
- **Merkle leaf bytes (per receipt).** `leaf = <<payload_len::32-big>> <> payload_jcs <> signature`, where `payload_len` is a big-endian 32-bit unsigned integer byte-length of `payload_jcs`. Length prefix is load-bearing (it disambiguates the payload/signature boundary even if future variants use a signature scheme with a different fixed byte length). Leaves are then hashed via `leaf_hash(leaf) = SHA-256(0x00 || leaf)` per §4.2.3. Verifiers MUST validate `leaf_bytes.size == 4 + payload_len + expected_signature_size` for the declared `signature_algorithm`; a leaf with trailing garbage is malformed and MUST reject.
- **Leaf order.** Receipts within an epoch are sorted by `(inserted_at ASC, id ASC)` — deterministic total order. `id` is the Ash UUID primary key of the receipt row; byte-lexicographic comparison of the lowercase-hyphenated UUID string.
- **Empty epoch sub-root.** If an epoch contains zero operator or zero execution receipts, the corresponding sub-root is `SHA-256(<<>>)` (see §4.2.3 empty leaf list). The anchor root is still `SHA-256("wallop-anchor-v1" || op_root || exec_root)` over those sub-roots.
- **Hex encoding.** `anchor_root`, `op_root`, and `exec_root` are each serialised as lowercase 64-character hex (no prefix, no whitespace) per §4.2.2.
- **Anchor envelope (signed bytes).** The infrastructure signature is over `JCS({schema_version, anchor_root, op_root, exec_root, epoch_start, epoch_end, signing_key_id})`. `schema_version` is `"1"` for this anchor shape. Verifiers MUST reject anchors whose `schema_version` they do not recognise. `signing_key_id` identifies which infrastructure signing key issued this anchor under the generic key-identity rules in §4.2.4. The JCS canonicalisation is the same rule used for receipts.
- **Signature.** The envelope above is signed with the wallop infrastructure Ed25519 key. The key's identity, resolution, and revocation semantics are covered by §4.2.4.

#### 4.2.7 Cross-draw transparency commitment

The operator registry at `/operator/:slug` is the public surface for cross-draw verifiability. Its purpose is to make a specific class of attack — **post-hoc draw shopping** — externally detectable: an operator who locks a draw, observes an unfavourable outcome, abandons it, and re-locks the same entry set at a fresh sequence slot. Without a public listing, an outside auditor cannot tell that the discarded draw ever existed; with one, the discarded slot remains publicly visible by sequence number, and the operator's signed lock receipt for that slot commits them to the abandoned attempt.

For this property to hold, the listing surface MUST satisfy:

- **Per-operator sequence numbers assigned at create time, monotonically increasing, with no gaps in the publicly listed (non-`:open`) subset.** Numbers are allocated inside an advisory-locked transaction via `MAX(operator_sequence) + 1`; Postgres sequences are avoided because they leak gaps on rollback. Pre-lock deletion of an `:open` draw MAY compact the counter — this is invisible to auditors by design and outside the cross-draw-shopping attack model, which only commits operators via signed lock receipts. Once a draw transitions out of `:open`, its slot is permanent (see "sequence-slot immutability post-lock" below).
- **Every draw with a signed lock receipt is publicly visible** at `/operator/:slug` regardless of subsequent state. Concretely, draws in `:locked`, `:awaiting_entropy`, `:pending_entropy`, `:completed`, `:failed`, and `:expired` states all appear. Hiding `:failed` or `:expired` draws — even by an operator's UI preference — re-opens the post-hoc-draw-shopping attack: an auditor cannot detect a sequence gap they cannot see.
- **Open draws are NOT listed.** A draw in `:open` status is operator working state — entries can still be added or removed — and has no signed lock receipt. Sequence numbers are assigned at create time so an `:open` draw does occupy a slot, but listing it would expose unfinalised activity outside this commitment's scope. Status (`status != :open`) is the discriminator, not the presence of `operator_sequence`.
- **Sequence-slot immutability post-lock.** Once a draw transitions out of `:open`, the value of `operator_sequence` cannot be mutated. The reference implementation enforces this via the `prevent_draw_mutation` trigger (`operator_sequence` is in the post-`:open` protected-fields set, alongside `entry_hash` and `entry_canonical`).
- **Lock-receipt persistence.** The signed lock receipt for every assigned sequence slot is retained for the life of the 1.x major (per §4.4 Historical verifiability). A slot that exists in the listing but whose lock receipt is no longer reachable is indistinguishable from a tampered listing and MUST be treated as such by auditors.
- **Operator slug stability.** The `:slug` path component on `/operator/:slug` is the public anchor for the listing and MUST be immutable for the life of the operator identity. A rotating slug would empty the listing at the previous URL and recreate it at the new one, opening a trivial bypass of the post-hoc-draw-shopping defence. The reference implementation enforces immutability via the `operator_slug_immutability` DB trigger; the slug appears in every signed receipt's payload (`operator_slug` field) so a slug change on the operator row would invalidate every prior lock receipt's signature anyway, but the trigger forecloses the attempt at the storage layer. The `slug → operator_id → operator signing keyring` resolution is covered by §4.2.4.

This commitment is the public-listing complement to the anchor-based tampering detection in §4.2.6: anchors prove no receipt was retroactively altered or removed; the listing proves no sequence slot was ever quietly skipped. Together they bound the attack surface against an operator-side adversary who controls only their own keying material.

The listing is intentionally readable without authentication. Operators MAY use other surfaces (operator dashboard, admin tooling) to query their full draw history including unsequenced working state; those surfaces are operator-facing and out of scope for this commitment.

### 4.3 NOT frozen at 1.0.0

The following surfaces are explicitly **not** part of the 1.x stability contract. Consumers SHOULD NOT pin behaviour against them.

- **HTTP response shapes on non-proof endpoints**. Operator-facing, authenticated, and LiveView responses can evolve additively in minor releases. The proof bundle is explicitly NOT in this class — it's frozen under §4.2.5.
- **Internal `Draw` resource fields**. Fields returned inside the proof bundle are frozen (§4.2.5). Fields present on the Ash resource but not exposed in the public bundle are free to evolve *within scope* — new internal fields MUST NOT introduce identity, ticketing, payment, or buyer-facing semantics per §4.6, even if they live outside the signed-byte surface.
- **Operational knobs**. Rate limit thresholds, retry policies, entropy attempt caps, worker queue configuration, Oban pruning windows, weather fallback attempt budgets. None of these appear in signed bytes; none are protocol.
- **Webhook payload schema**. Webhooks are operational. Additive changes in any 1.x release are permitted. The one protocol-adjacent commitment: **webhook payloads will not expose information beyond what is already in the proof bundle.** Webhooks are a push-notification convenience, not a second protocol surface.
- **On-disk storage conventions** (database schema columns beyond what is surfaced in the proof bundle, filesystem layout, cache layouts). The bytes a verifier consumes are protocol; how those bytes are stored is not. **Separately**: wallop retains the raw inputs needed to reconstruct a proof bundle (weather API response, drand beacon payload) for at least the lifetime of the 1.x major. A proof bundle fetched two years post-draw still verifies against live wallop; operators requiring longer retention SHOULD archive bundles themselves.
- **Error message strings** returned to operators or rendered on the proof page. Copy may evolve in any release, with one protocol-adjacent rule: **error strings MUST NOT leak entry UUIDs, entry counts, or draw internals beyond what is already in the proof bundle.** Observability leaks via error messages are a classic privacy footgun; copy changes don't get to reintroduce them.

- **Observable side channels** on public proof endpoints (HTTP status codes, response timings, `Cache-Control` and `Server-Timing` headers, `ETag` values, rate-limit response headers). These SHOULD NOT differentiate between draw states in ways that reveal information absent from the public proof bundle. Specifically: a draw that exists but hasn't reached the stage a caller is asking about, and a draw that does not exist, SHOULD return the same status code and body shape to an unauthenticated caller. Timing oracles on entry-existence checks: response times on self-check endpoints SHOULD NOT materially vary with hit vs miss. A measurable version of this rule (e.g. "p99 differential ≤ Nms under a reference load harness") is follow-up work for the pre-1.0.0 infra-hardening audit; until that ships, implementations aim for indistinguishability in the qualitative sense and document any known oracle. **If that audit does not land before 1.0.0 final, this bullet stays qualitative; the qualitative form is the 1.x floor and a measurable form can only be introduced additively (never as a normative strengthening of existing SHOULDs — that would be a v2.0.0 under §4.1).**

### 4.4 Historical verifiability

Every receipt ever produced by a wallop_core version **≥ 0.16.0** remains verifiable for the life of the 1.x series.

- A verifier that understands lock receipt v4 and execution receipts v2 **and** v3 continues to verify every draw locked from wallop_core 0.16.0 onwards. `wallop_verifier` ≥ 0.9.0 provides this dual-version support; earlier verifier versions that understand only v2 can verify v0.16.x-era receipts but MUST reject anything labelled `"3"` per §4.2.1.
- Future 1.x verifier releases MAY add support for newer schema versions without removing support for previously-frozen versions. `schema_version` is the discriminator.
- v0.15.x and earlier receipts are not covered by this contract. They exist only in pre-launch dev environments and are historical curiosities; no 1.x verifier is obliged to reproduce their bytes.
- **Keyring retention trust assumption (operational, not cryptographic).** Historical verifiability for the life of 1.x requires the wallop operator to retain every infrastructure signing key used to sign any 1.x-era execution receipt or transparency anchor, for the duration of 1.x. A key that is rotated remains in the keyring (marked `revoked_at` per §4.2.4 revocation semantics), not removed. A verifier that encounters an unresolvable `signing_key_id` on a historical receipt MUST reject per §4.2.4 — this is what makes the retention commitment load-bearing for goal 3 (no holes). Operators who, for any reason, cannot meet this retention commitment for 1.x MUST declare that at deployment time; downstream verifiers have no way to distinguish "key rotated out" from "receipt tampered" if the keyring is incomplete.
- **Weather observation attestation trust assumption (operational, not cryptographic).** `weather_value` and `weather_observation_time` in the signed execution receipt are recorded by wallop_core's entropy worker and NOT independently attested by the Met Office. The §4.2.5 window bounds *when* the observation must fall, not *which* observation was selected. A wallop infrastructure compromised between drand-round publication and receipt signing could retry within the window until a favourable observation appeared; the attacker is bounded to observations the Met Office actually published for `weather_station` across the window (fabrication is impossible), but selection within that set is not cryptographically detectable from the single-draw proof alone. Transparency anchors (§4.2.6) do not mitigate intra-window retry; they detect only post-execution rewriting of a completed draw. Known residual trust assumption of the 1.x protocol.
- **drand BLS attestation trust assumption (operational, not cryptographic).** wallop_core's producer does NOT verify the drand BLS signature when fetching a beacon; it trusts the drand relay's TLS chain to deliver an honest `(round, randomness, signature)` tuple and commits those bytes verbatim into the signed execution receipt. Any verifier consuming the receipt re-verifies the BLS signature off the receipt bytes against the public chain key (`drand_chain` in the signed payload), so a forgery introduced between the drand relay and the producer is detectable downstream and the receipt rejects at verification. The producer also trusts the relay for the current-round number it commits as `drand_round` on the **lock** receipt; a relay that lies about the current round at lock time would let a colluding producer pin a round it can grind. That gap is bounded by two complementary checks: the cross-receipt consistency rule in §4.2.5 (the execution receipt's `drand_round` MUST equal the lock receipt's `drand_round`, byte-identical) and the verifier-side BLS check on the eventual execution receipt — so the grinder's chosen round must still verify against the public chain key with its actually-published bytes. The trust assumption is therefore narrow: a producer compromised together with the drand relay — or a TLS MITM between them — can sign one bad-bytes receipt that the verifier-side check correctly rejects, but the resulting `failed`/`completed`-with-bad-bytes draw lives forever in the operator's public listing as a publicly visible artefact that cannot be silently corrected. No fairness invariant is broken; verifiers reach the right verdict. The cost of the assumption is a UX failure mode, not a fairness failure mode. Closing it would require running drand BLS verification producer-side as well as verifier-side, which is out of scope for 1.x (goal 2).
- **Single-node rate-limit trust assumption (operational, not cryptographic).** The per-IP, per-API-key, and per-self-check rate-limit buckets are stored in node-local ETS and are not replicated across BEAM nodes. wallop_core 1.x ships single-node; running multiple nodes behind a load balancer would multiply each bucket's effective ceiling by node count, which is not the rate-limit guarantee the documentation makes. Operators MUST keep the deployment single-node, or replace the rate-limit storage with a distributed counter (e.g. Hammer with Redis, or a Postgres NOTIFY-backed counter), before scaling out. No commitment, receipt, or seed byte depends on rate-limit state; the assumption is purely an operational constraint on horizontal scale-out and a documented limit on what "we rate-limit per IP" means as deployed.
- **API key compromise blast radius trust assumption (operational, not cryptographic).** A compromised api_key can perform every action that key was authorised to perform, including locking any of the operator's open draws — which commits the entry set and starts the entropy pipeline. wallop_core 1.x does not provide per-action capability flags on api keys; key compromise is a full takeover of that key's draws. Operators are responsible for key custody and rotation. Deactivating a compromised key (via `:deactivate` on the `ApiKey` resource) stops new requests immediately, but does NOT invalidate in-flight Oban work that was authorised before deactivation: the entropy and webhook flows complete on draws that were authorised at create time, by design. The resulting lock or execution receipt is a permanent artefact of the historical authorisation window, not of the current authorisation state — known 1.x limitation, candidate for revisit post-1.0 if operator demand justifies the added surface area. The transparency listing in §4.2.7 makes the gap observable: every locked draw is publicly visible from lock time onwards, so a surprise lock by a stolen key is detectable by any party watching the operator's registry, even if not preventable in-flight.
- **Entropy-queue ordering trust assumption (operational, not cryptographic).** Entropy fetches are processed FIFO with bounded concurrency from a single shared Oban queue. A single authenticated operator can extend other operators' draw-completion latency by minutes by exhausting their per-key HTTP rate limit and saturating the queue with concurrent locks. This is a scheduling property, not a fairness property — the determinism of `winner = fair_pick(entries, seed)` is unaffected because `drand_round` is committed and signed in the lock receipt at lock time, before any worker fires. A delayed worker fetches the same round-N beacon bytes and binds the same entropy. The producer MUST fail the draw if the committed round becomes unavailable rather than substitute a later round (the reference implementation enforces this — the entropy worker retries the same `(chain, round)` and routes to `:failed` on permanent error, never advancing the round). Worst-case cross-tenant influence is therefore bounded to execution timeliness, not outcome. Mitigation is bounded by the per-key HTTP rate limit; an additional per-key per-day cap is a planned 1.x-or-later hardening tracked separately. Re-open trigger: any operator reports sustained starvation, or observed queue depth exceeds 100 jobs for more than 5 minutes in production at current operator scale. At that point the right next steps are per-tenant fairness (round-robin across api_key_ids) or a per-tenant concurrency cap — both achievable additively without changing any signed bytes or schema.

### 4.5 Reference implementations

Three implementations are maintained in lockstep. A claim is only part of the protocol if it produces byte-identical output in all three against every frozen test vector:

| Implementation | Repo | Language | 1.0.0 floor |
|---|---|---|---|
| `wallop_core` | `wallop` (this repo) | Elixir | v1.0.0 |
| `wallop_verifier` | `wallop-verifier` | Rust (native + WASM) | v0.9.0 |
| Reference CLI verifier | `wallop-verifier` | Rust binary (`wallop-verify`) | v0.9.0 |

Cross-language parity is enforced in CI via shared frozen vectors (wallop's `spec/vectors/`, vendored into `wallop_verifier` via git submodule). Any divergence between implementations is a bug in whichever one disagrees with the spec — not a new spec variant.

### 4.6 What 1.0.0 is not trying to be

For the avoidance of doubt, and for the future reviewer holding a clever idea: **no**.

- wallop_core is a **fairness service**. It does not know about payments, buyers, tickets, sale channels, prices, refunds, or customer identity. Any binding between an entry UUID and any of those lives in a consumer layer above wallop.
- **No reserved-for-future-use fields.** No `manifest_ext_hash`, no `extensions`, no `reserved_for_later`. If a future consumer has a real use case that demands a new signed commitment, they design it, justify it against the six goals in `CLAUDE.md`, and it gets a 2.0.0. Reserving slots is scope creep disguised as foresight.
- **No per-draw operator-supplied metadata**: no tags, no labels, no display descriptions, no external-system references, no notes field. `operator_ref` was the last one of these and we purged it in 0.16.0 for a reason.
- **No buyer-facing endpoints.** No "find my entry" lookup, no self-service "was I in this draw," no "tell me my odds." Buyers are the operator's customers; wallop serves operators.
- **No analytics, metrics, or observability emission that carries entry UUIDs, draw content, or anything beyond counts and timings.** Operational metrics (request rates, error counts, queue depths) are fine. Leaking draw content through observability is a classic privacy footgun for this class of service.
- **No automated revocation-triggered re-signing.** Revocation is forward-only. Historical receipts signed by a now-revoked key remain permanently valid. No cascade re-issuance, no post-hoc updates, no "please re-sign everything under the new key" flow.
- **Transparency-log / witness co-signing** of proof bundles is out of scope for 1.x. The `transparency_anchors` artefact is wallop's own anchor, not a third-party witness mechanism.
- **Inclusion proofs for individual entries** from the Merkle root are not emitted by `wallop_core` — the primitive is there for the `transparency_anchors` use case; proof emission is a consumer concern if anyone's.
- **No email normalisation, Unicode casefolding, Argon2id, or KDF parameters of any kind.** All were proposed during the cancelled manifest work. All are operator / consumer concerns if they exist anywhere. wallop_core does not hash identity.
- No field in any signed artefact exists to describe *how an entry came to exist*. Entries appear in the proof bundle as `{uuid, weight}` and nothing more.

The 1.x protocol is small enough that a motivated third party can read this document in one sitting and implement a working verifier in a weekend. Keeping it that way is the whole job.

**A future reviewer reading this list with a case that feels different: write the justification against the six goals in `CLAUDE.md` first. If that justification is two sentences long, close your laptop.**

---

## Appendix A: Project structure

| Component | Repo | Description |
|-----------|------|-------------|
| `fair_pick` | `fair_pick` (separate repo) | Hex package. Pure deterministic algorithm. Open source from day one. |
| `wallop_core` | `wallop` (umbrella app) | Commit-reveal protocol, entropy fetching, API. Open source at launch. |
| `wallop_web` | `wallop` (umbrella app) | Proof pages, API key management, live draws. Open source at launch. |

The `wallop` repo is an Elixir umbrella application. `wallop_core` depends on
`fair_pick` (the hex package). `wallop_web` depends on `wallop_core`. The
umbrella boundary exists for architectural clarity and to allow future
extraction of `wallop_web` into a private repo if the business model requires
it.

All code is open source. Revenue comes from the hosted service (API usage,
proof page hosting, live draw features), not code licensing.

---

## Appendix B: Design rationale

Brief notes on why specific choices were made. For full architectural context,
see `docs/decisions/0001-picker-architecture.md`.

- **SHA256-counter PRNG over ChaCha20 or HMAC-DRBG:** SHA256 is universally
  available, trivial to implement, and the security properties of the PRNG are
  irrelevant (the seed is public). Simplicity and portability are the only
  criteria.

- **Rejection sampling over simple modulo:** Guarantees perfectly uniform
  distribution regardless of `n`. The bias from 256-bit modulo is
  astronomically small in practice, but a provably fair system should be
  provably unbiased.

- **JCS (RFC 8785) for canonicalization:** A real standard with a real RFC.
  Avoids inventing bespoke serialization rules that would need equally precise
  specification.

- **Two mandatory entropy sources:** The trust model requires that no single
  party can influence the outcome. Two independent sources mean compromising
  one is insufficient. Refusing to execute with a single source preserves this
  guarantee.

- **Weight support in the algorithm:** Entries carry a weight for generality.
  Callers that want equal probability for every participant can set all weights
  to 1. Weight support enables use cases where entries should have proportional
  chances (e.g. multiple tokens, tiered entry) without changing the algorithm.

- **Durstenfeld shuffle:** The standard modern Fisher-Yates variant. Well-known
  and unambiguous.
