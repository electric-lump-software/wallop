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
extra keys on entry maps have no effect on the hash (the canonical
form reads only `uuid` and `weight`); two entries sorted by uuid;
weight at 2^53-1 boundary; same entries in a different draw_id
produce a different hash.

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
