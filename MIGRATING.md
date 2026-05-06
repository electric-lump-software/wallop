# Migrating

Upgrade notes for `wallop_core` consumers. Listed newest-first. Each section is self-contained — follow every section between your current version and the target.

## Which sections apply to me?

`wallop_core` has three integration surfaces, with different upgrade implications. Identify your consumer type before reading any version section.

| Consumer type | Description | Sections that apply |
|---|---|---|
| **HTTP API consumer** | You call `wallop_core` over its HTTP API (`POST /api/v1/draws`, `PATCH /draws/:id/entries`, etc.) and consume webhooks. You don't depend on the `wallop_core` Hex package. | "HTTP API surface" subsection. |
| **Hex package consumer** | You include `wallop_core` as an Elixir dependency in your `mix.exs` and call its modules directly. | Both "HTTP API surface" and "Hex package surface" subsections — Hex consumers see everything HTTP consumers see, plus the Elixir-level changes. |
| **Verifier consumer** | You run `wallop_verifier` (Rust crate, WASM package, or CLI) to verify proof bundles. May or may not also be an HTTP / Hex consumer. | "Verifier surface" subsection. |

Within each version section, look for `### HTTP API surface`, `### Hex package surface`, and `### Verifier surface` headings. If a section is absent for your consumer type, that version had nothing breaking on that surface.

---

## 0.26.x → 1.0.0

The 1.0.0 tag freezes the protocol. The complete frozen set is in `spec/protocol.md` §4 ("Stability contract"). Read that document if you need an authoritative answer to "is this part of the contract?" — anything not listed there remains free to evolve in 1.x.

### HTTP API surface

**No breaking changes.** The protocol surface at 1.0.0 is byte-identical to 0.26.x. The bump exists to lock in the existing shape, not to change it.

### Hex package surface

**No breaking changes.**

### Verifier surface

Pin `wallop_verifier >= 0.16.0` if you are not already there. Older 0.x verifiers continue to work against historical receipts (older schema versions remain verifiable for the life of 1.x per `spec/protocol.md` §4.4), but new bundles produced under 1.0.0 are best paired with 0.16.0 or later.

---

## 0.25.x → 0.26.0

Optional operator-supplied `weather_time` on `Draw.lock`. **No HTTP breaking changes; no protocol or signed-byte changes.** Pure additive.

### HTTP API surface

`PATCH /api/v1/draws/:id/lock` now accepts an optional `weather_time` field (UTC datetime, ISO8601, second precision). When supplied, the entropy worker fires at this moment and the draw executes then. When omitted, defaults to the jittered 3-5 minutes from lock-time as before.

Use case: commit the entry set at sales-close-time, schedule actual draw execution for later (e.g. lock at 5pm today, draw at 6pm tomorrow). Without `weather_time`, you'd have to defer the lock call until just before execution, leaving the draw in `:open` on wallop while you treat it as closed.

Constraints (validated, errors return HTTP 400):

- Second precision only — sub-second values are rejected, not silently truncated.
- Must be at least 60 seconds in the future.
- Must be within ~7 days (201,600 drand quicknet rounds at 3s/round).

Atomic semantics preserved — `weather_time` is committed in the lock receipt at lock-time and cannot be revised. Cross-source binding maintained: the `drand_round` is derived from `weather_time`, so drand publishes ~30 seconds before the supplied moment regardless of when lock fires.

### Hex package surface

`Draw.lock` action gains an optional `:weather_time` argument (`:utc_datetime_usec`). Direct `Ash.Changeset.for_update/3` callers can supply it:

```elixir
target = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)

draw
|> Ash.Changeset.for_update(:lock, %{weather_time: target}, actor: api_key)
|> Ash.update!()
```

Existing callers omitting the argument see identical behaviour to 0.25.x.

New validator: `WallopCore.Resources.Draw.Validations.WeatherTime`. New constants on `DeclareEntropy`: `@drand_slack_seconds 30` (drand publishes this many seconds before `weather_time`).

### Verifier surface

**No verifier change.** Lock receipt v5 schema unchanged — `weather_time` was already a signed field. Only the value is now operator-controlled. Cross-language vectors unchanged.

---

## 0.24.x → 0.25.0

Pre-lock proof page hardening. **No HTTP breaking changes; no protocol or signed-byte changes.** Internal-only structural firewall.

### HTTP API surface

**No breaking changes.** The public proof page at `/proof/:id` and `/live/proof/:id` continues to render the same fields it always has on `:open` draws: id, name, status, winner_count, entry_count, opened_at, check_url, operator_sequence, operator slug + name. Adding new fields to the page now requires a deliberate one-line change to the build-side allowlist (`WallopWeb.ProofPreLockView`) plus an update to `spec/vectors/pre_lock_wide_gap_v1.json`.

A new rate-limit bucket fires on pre-lock reads (120/min per IP). Distinct from the existing self-check rate limit. Bots scraping pre-lock state at high frequency will see HTTP 429 sooner; legitimate viewers including LiveView polling are well under the cap.

### Hex package surface

New module `WallopWeb.ProofPreLockView` with `from_draw/2`. New component `WallopWeb.Components.PreLockPanel`. New plug `WallopWeb.Plugs.ProofPreLockRateLimit` (table `:wallop_proof_pre_lock_rate_limit`, separate from `:wallop_self_check_rate_limit`). No removals.

### Verifier surface

`spec/vectors/pre_lock_wide_gap_v1.json` is the cross-language vector for the pre-lock allowlist. Verifiers consuming the public proof page on `:open` draws MUST treat any field outside this vector's allowlist as out of contract.

Spec §4.3 now pins the proof-page fingerprint as **undefined for pre-lock draws**. Verifiers MUST reject any fingerprint claim attached to a draw not yet locked.

---

## 0.23.x → 0.24.0

Idempotent `add_entries` retries via operator-supplied `client_ref` (ADR-0012).

### HTTP API surface

**BREAKING.** `PATCH /api/v1/draws/:id/entries` now requires a `client_ref` field alongside `entries`. Calls without it return HTTP 400.

`client_ref` is an opaque idempotency token chosen by the caller — 1..256 bytes, generated fresh per batch. Use a UUID or other high-entropy random value. Do **not** use semantically meaningful or guessable identifiers; the value is hashed at the request boundary but the digest is persisted, and weak inputs are theoretically rainbow-table-able.

Behaviour:

- First request with a given `(draw_id, client_ref)` lands and stores the resulting entry UUIDs.
- A retry with the **same** `(draw_id, client_ref)` and the **same multiset of entries** replays the original response (same `meta.inserted_entries[*].uuid`). No double-insert. Reordering entries between requests is fine — the comparison is over the canonical multiset, not byte-equality of the request body.
- A retry with the same `client_ref` but a different multiset of entries returns **HTTP 409** with `code: "idempotency_conflict"`. Pick a fresh `client_ref` for each logically distinct batch.
- Once the draw is locked, idempotency rows are pruned in the same transaction as the lock; `add_entries` itself is rejected unconditionally on locked draws.

Migration cost is one new field per request. Recommended: generate `client_ref` at batch construction time alongside the entries you are about to send, store it on your side keyed by your retry-aware identifier (eg. the queue message id), and re-send the same value on retry.

The flat `%{entries: [...]}` request shape and the JSON:API `{data: {attributes: {entries: [...]}}}` shape both accept `client_ref` at the same level as `entries`.

### Hex package surface

The `Draw.add_entries` action now takes a required `:client_ref` argument. Direct `Ash.Changeset.for_update/3` callers must pass it:

```elixir
draw
|> Ash.Changeset.for_update(:add_entries, %{
  entries: [%{"weight" => 1}],
  client_ref: Ash.UUID.generate()
}, actor: api_key)
|> Ash.update!()
```

New module: `WallopCore.Protocol.ClientRef` with `client_ref_digest/2` and `payload_digest/2`. The constructions are documented for cross-language re-implementation; see ADR-0012. New error: `WallopCore.Errors.IdempotencyConflict` (mapped to HTTP 409 by `WallopWeb.DrawEntriesController`).

New resource: `WallopCore.Resources.AddEntriesIdempotency` (internal-only; `forbid_if(always())` on every action). Operational table only — never read during receipt construction.

### Verifier surface

**No verifier change.** Idempotency state is operational, not protocol. No receipt schema bump, no signed-byte change, no frozen-vector regeneration. A wholesale wipe of the new table mid-flight produces zero bit-flip in any signed artefact.

---

## 0.21.x → 0.22.0

### HTTP API surface

**Additive only.** New endpoint: `GET /operator/:slug/keyring-pin.json` — unauth'd, public, signed pin envelope per spec §4.2.4 tier-1 verification. 404 on unknown slug or pre-bootstrap state. Returns a `{schema_version, payload, signature}` envelope; consumers that don't use tier-1 verification can ignore it.

### Hex package surface

New module: `WallopCore.Protocol.Pin` (sibling to `WallopCore.Protocol`). Public functions: `schema_version/0`, `domain_separator/0` (the frozen 14-byte `"wallop-pin-v1\n"`), `build_payload/1`, `sign/2`, `verify/3`, `build_envelope/2`. No existing surface changes.

### Verifier surface

Pin `wallop_verifier >= 0.16.0` to consume the keyring-pin endpoint via the bundled `PinnedResolver`. Older verifiers do not need to bump; the pin endpoint is opt-in.

---

## 0.20.x → 0.21.0

### HTTP API surface

**BREAKING.** `GET /operator/:slug/keys` no longer includes a top-level `operator` block. The new shape is exactly the spec §4.2.4 canonical envelope:

```json
{ "schema_version": "1", "keys": [ { "key_id": "...", "public_key_hex": "...", "inserted_at": "...", "key_class": "operator" } ] }
```

Consumers that need operator metadata (`{id, name, slug}`) should call `GET /operator/:slug` (unsigned, free to evolve) instead.

### Verifier surface

Pin `wallop_verifier >= 0.15.0`. Earlier verifiers expecting the `operator` envelope reject the new response as `MalformedResponse`.

---

## 0.19.x → 0.20.0

### HTTP API surface

Two changes:

1. **Additive:** new endpoint `GET /infrastructure/keys` returns the full infrastructure-key history in the same `{schema_version, keys[]}` shape as `/operator/:slug/keys`. The existing singular `GET /infrastructure/key` (raw 32-byte body) is unchanged.
2. **Wire shape on `/operator/:slug/keys`:** the response gains a top-level `schema_version: "1"`. The per-key `valid_from` field is **removed** — pre-launch breaking change, no published verifier consumed it. Canonical pin row is now `{key_id, public_key_hex, inserted_at, key_class}`.

### Verifier surface

Pin `wallop_verifier >= 0.14.0` for verifiers that consume `/operator/:slug/keys` directly. Earlier verifiers reading `valid_from` from the response break.

---

## 0.18.x → 0.19.0

### HTTP API surface

**BREAKING for verifier consumers; transparent for HTTP API consumers.** Producer-side schemas bump: lock receipt `"4"` → `"5"`, execution receipt `"3"` → `"4"`. Field set on both signed payloads is byte-identical to predecessors — the bump is a coordination flag for verifier behaviour. New (v5/v4) receipts are paired with bundle wrappers that **omit** the inline `operator_public_key_hex` / `infrastructure_public_key_hex`. Verifiers resolve those keys via `KeyResolver` against `/operator/:slug/keys` (attestable mode) or an operator-published keyring pin (attributable mode) per §4.2.4.

Historical bundles keep their inline wrapper keys. `WallopCore.ProofBundle.build/1` reads each receipt's signed `schema_version` and emits the wrapper conditionally.

### Verifier surface

Pin `wallop_verifier >= 0.12.0`. The `BundleShape` step enforces the v5/v4 wrapper-omits-keys consistency rule and rejects mismatches as downgrade-relabel or upgrade-spoof attempts. Historical v2/v3/v4 receipts continue to verify under the dual-version parsers.

---

## 0.16.x → 0.17.0

### HTTP API surface

**No breaking changes for HTTP consumers.** Endpoints, webhook payloads, proof bundle shape, and receipt endpoints are byte-compatible on every field other than the execution receipt's signed payload — which gains `signing_key_id` and bumps `schema_version` `"2"` → `"3"`.

If your JSON parsing is non-strict (ignores unknown keys), no change required. If you have a strict schema validator that rejects unknown fields on the execution receipt JSON, update it for the v3 shape.

### Hex package surface

`WallopCore.Protocol.build_execution_receipt_payload/1` now requires `:signing_key_id` in its input map. Calls without it raise `FunctionClauseError`. The orchestrator inside `wallop_core` handles this automatically via the loaded infrastructure key — **no change required** if your code goes through public Ash actions or the HTTP surface.

### Verifier surface

Pin `wallop_verifier >= 0.9.0`. Both v2 and v3 receipts remain verifiable; the verifier dispatches on `schema_version` and uses exact-field-set parsers (`#[serde(deny_unknown_fields)]`) to reject downgrade-relabel and upgrade-spoof attempts.

Operators commit to retaining every infrastructure signing key used to sign any 1.x-era receipt or anchor for the life of 1.x. A verifier encountering an unresolvable `signing_key_id` MUST reject per §4.2.4.

---

## 0.15.x → 0.16.0

### HTTP API surface

This is the upgrade with the most code changes for HTTP consumers.

1. **Capture wallop UUIDs from the `add_entries` response.** `meta.inserted_entries: [{uuid}]` now appears on every `PATCH /api/v1/draws/:id/entries` response, in submission order. `meta.inserted_entries[i].uuid` corresponds to `request.entries[i]`. You **must** store the `(your-id ↔ wallop-uuid)` mapping at submit time — wallop_core no longer retains operator references and cannot reconstruct it later.
2. **Read winners by `entry_id` in `GET /draws/:id`.** Webhook payloads carry only `{draw_id, status}`. The `results` array on the draw response uses the field name `entry_id` (a wallop UUID).
3. **`add_entries` is NOT idempotent on retry.** The previous `(draw_id, entry_id)` unique constraint was dropped with `operator_ref`. Gate retries client-side; a server-side idempotency-key header is post-1.0 roadmap.
4. **`:execute` action removed.** Draws auto-execute when entropy is ready. Remove any code that POSTed to `/draws/:id/execute`; wait for the completion webhook or poll `GET /draws/:id`.
5. **Lock receipt schema v4** commits algorithm identity tags (`picker_algorithm`, `seed_derivation`, etc.). `weather_fallback_reason` is now a frozen enum: `"station_down"`, `"stale"`, `"unreachable"`, or `null` — audit any branches on string contents.

### Hex package surface

- The `:execute` action and `NoEntropyDeclared` validation are removed.
- `WallopCore.Resources.Entry.operator_ref` is removed; any code reading it breaks at compile or run time.
- Lock and execution receipt builders accept new arguments for the algorithm pins.

### Verifier surface

Pin `wallop_verifier >= 0.8.0` for v4 lock receipts and v2 execution receipts.

---

## Earlier versions

Pre-0.15 versions are not documented here. If you are upgrading from earlier than 0.15, please file an issue and we'll write the section.
