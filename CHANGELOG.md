# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- Bump `ash` 3.21.3 → 3.24.4 to close GHSA-jjf9-w5vj-r6vp (atom exhaustion via unchecked `Module.concat` in `Ash.Type.Module.cast_input/2`, HIGH severity, vulnerable versions ≤ 3.21.3, first patched 3.22.0). Surfaced by the new `mix deps.audit` step in CI.

### Tests / vectors — operator key rotation regression (§4.2.4)

**ADDED.** Cross-language regression test for operator key rotation, locking in the four cross-key cases byte-for-byte across implementations.

- New cross-language conformance vector: `spec/vectors/key-rotation-bidirectional.json`. Two deterministic operator keypairs with non-overlapping active windows, three lock-receipt v5 payloads (pre-rotation, post-rotation, and a backdated-after-rotation case for the "Ed25519 verify has no forward lower bound" assertion), and five recorded verification cases: historical-receipt-with-original-key (pass), post-rotation-receipt-with-new-key (pass), pre-rotation-receipt-against-post-rotation-key (fail), post-rotation-receipt-against-pre-rotation-key (fail), and Ed25519-verify-has-no-forward-lower-bound (pass — pins that temporal binding is a pipeline-level concern, not a primitive concern). Plus a `key_id_derivation` block pinning the first-4-bytes-of-`SHA-256(public_key)` rule.
- New Elixir consumer: `apps/wallop_core/test/wallop_core/protocol_key_rotation_test.exs`. Loads the same vector and asserts identical verdicts.
- Verifier-side consumer (Rust) lands separately in `wallop_verifier` and consumes the vector via the existing `vendor/wallop` submodule pin.

No spec text change (§4.2.4 already specs `key_id` derivation, `revoked_at` forward-only semantics, and temporal binding). No producer-side code change. No schema bump. Pure regression coverage for already-specced behaviour, providing forever-pinned cross-language parity going into 1.0.0.

### wallop_core 0.22.0 — signed keyring pin producer (§4.2.4)

**ADDED.** Producer-side implementation of tier-1 attributable verification per spec §4.2.4. New endpoint, new module, new cross-language conformance vector.

- New endpoint: `GET /operator/:slug/keyring-pin.json` — unauth'd, public, lazy-signed per request from the current keyring snapshot. `Cache-Control: public, max-age=60`. Returns 404 for unknown slug, no operator keys yet, or no infrastructure key bootstrapped (all "outside attributable mode" per spec). Returns 503 on Vault decrypt or keyring-row inconsistency (genuine outage).
- New module: `WallopCore.Protocol.Pin`. Sibling to `WallopCore.Protocol`, separate canonical-bytes producer for the pin envelope. Public surface: `schema_version/0`, `domain_separator/0` (the frozen 14-byte `"wallop-pin-v1\n"`), `build_payload/1`, `sign/2`, `verify/3`, `build_envelope/2`. Producer obligations enforced at the module boundary: `keys[]` non-empty, sorted ascending by `key_id`, `key_class == "operator"` on every row, no duplicate `key_id`s.
- New cross-language conformance vector: `spec/vectors/pin/v1/valid.json`. Deterministic Ed25519 keypair, three operator keys, full signed envelope, JCS pre-image bytes, and four negative cases (one-byte preimage mutation, signature-byte mutation, wrong key, domain-separator-omitted) so a re-implementer cannot pass a broken consumer-side flow.

The verifier-side consumer (`PinnedResolver` in `wallop_verifier`) lands separately and consumes this vector via the existing `vendor/wallop` submodule pin. No protocol-level wire change beyond what §4.2.4 already specified — this is the implementation that was pinned to the spec text in v0.21.0's release.

### wallop_core 0.21.0 — scope correction: `/operator/:slug/keys` removes the `operator` block

**BREAKING.** The `/operator/:slug/keys` response no longer includes a top-level `operator` block. The new shape is the spec §4.2.4 canonical envelope and nothing else:

```json
{
  "schema_version": "1",
  "keys": [
    { "key_id": "...", "public_key_hex": "...", "inserted_at": "...", "key_class": "operator" }
  ]
}
```

**Why now.** The `operator` block was a wallop-side friendly extension predating the spec freeze: `{id, name, slug}`. None of those fields are load-bearing for `winner = fair_pick(entries, seed)` or for trust-root key resolution. They are operator-identity decoration that belongs above the verifier protocol surface, not on a signed-key endpoint.

A live smoke test against `wallop_verifier 0.15.0` (which adds `#[serde(deny_unknown_fields)]` to `KeysResponse` per spec §4.2.4 closed-set discipline) caught the divergence: the verifier rejects the operator response as `MalformedResponse` because of the extra envelope field. Loosening the verifier would have re-opened the wire-drift hole the closed-set rule explicitly closes; codifying the friendly extension into the spec would have baked operator-identity decoration into the protocol surface forever. Both alternatives lose the discipline. Removing the field on the producer side is the only fix that preserves it.

**Precedent.** Same shape as the `operator_ref` deletion in v0.16.0 and the v0.17.0 ticket-manifest reversal: surface area on a protocol endpoint is non-negotiable, even when the extra field looks harmless. Each one was caught and removed because allowing the friendly extension would have walked the protocol toward operator-identity / ticketing concerns the goals (1, 4, 5) tell us belong above wallop. This is the same trap dressed differently.

**Migration.** Consumers needing operator metadata should use `GET /operator/:slug` (the LiveView page; unsigned, free to evolve). The verifier endpoint remains minimal.

**Spec text tightened.** §4.2.4 now states the envelope is closed-set under `schema_version: "1"` explicitly: "The response object MUST contain exactly the top-level members `schema_version` and `keys`, and no others." Without this sentence the closed-set rule was implicit; the next reviewer hits the same trap.

**Server-side regression test.** Both `/operator/:slug/keys` and `/infrastructure/keys` now have a controller test pinning the envelope to exactly `{schema_version, keys}` and the row to exactly `{key_id, public_key_hex, inserted_at, key_class}`. The next friendly extension fails CI before it reaches a smoke test.

### wallop_core 0.20.0 — `/infrastructure/keys` JSON endpoint + `schema_version` on `/operator/:slug/keys`

Adds the JSON keys-list endpoint for infrastructure signing keys, mirroring the existing `/operator/:slug/keys` shape. Resolver-driven verifiers (the forthcoming `EndpointResolver` and `PinnedResolver` in `wallop_verifier`) consume both endpoints to look up infrastructure keys for execution-receipt verification.

**New endpoint:** `GET /infrastructure/keys` — returns the **full** infrastructure key history (current + rotated) as JSON in the canonical shape per spec §4.2.4:

```json
{
  "schema_version": "1",
  "keys": [
    {
      "key_id": "...",
      "public_key_hex": "...",
      "inserted_at": "2026-04-26T12:34:56.789012Z",
      "key_class": "infrastructure"
    }
  ]
}
```

The existing `GET /infrastructure/key` (singular, raw 32-byte response) is preserved for callers that already consume it (the wallop-verify CLI's belt-and-suspenders pin path, third-party scripts).

Rotated keys are included in the JSON list so historical execution receipts and transparency anchors remain verifiable for the life of 1.x per spec §4.4. The list is sorted ascending by `valid_from` (oldest rotation first). The `current_key/0` filter on the singular endpoint is unchanged — it still returns only the active rotation slot.

**Wire-shape changes on `/operator/:slug/keys`:**
- The response now includes a top-level `schema_version: "1"` field, matching the spec §4.2.4 canonical shape and the new infrastructure endpoint. The previous response didn't have one. Additive — existing consumers that ignore unknown fields are unaffected.
- The per-key `valid_from` field is **removed** from the response. Producer-side signing-eligibility state held within ±60 s of `inserted_at` by the keyring CHECK constraint; emitting it on the wire would invite resolver implementations to use it as the temporal-binding comparison point instead of `inserted_at`, reopening the backdating window. Pre-launch breaking change — no published verifier consumed this field. The canonical pin row is now `{key_id, public_key_hex, inserted_at, key_class}`.

The `schema_version` is pinned per controller via the `@keys_response_schema_version` module attribute on each controller. A bump is a coordinated wallop_verifier release.

### wallop_core 0.19.0 — emit lock v5 / execution v4 receipts (resolver-driven verification)

Producer-side schemas bump: lock receipt `schema_version` `"4"` → `"5"`, execution receipt `"3"` → `"4"`. Field set on both signed payloads is byte-identical to predecessors — the bump is a coordination flag for verifier behaviour, not a payload change. v5 lock and v4 execution receipts MUST be paired with bundle wrappers that **omit** the inline `operator_public_key_hex` / `infrastructure_public_key_hex`. Verifiers resolve those keys via `KeyResolver` against `/operator/:slug/keys` (attestable mode) or an operator-published `.well-known/wallop-keyring-pin.json` (attributable mode) per spec §4.2.4.

**Backwards compatibility.** Historical draws keep their inline wrapper keys. `WallopCore.ProofBundle.build/1` reads each receipt's signed `schema_version` and emits the wrapper conditionally — old receipts (lock v4, execution v2 / v3) continue to ship inline keys; new receipts (lock v5, execution v4) omit them. Receipt bytes in the database are immutable, so historical proofs remain verifiable indefinitely under the existing wallop_verifier paths. The verifier crate's `BundleShape` step (shipped in `wallop_verifier 0.12.0`) enforces the consistency rule and rejects mismatches as downgrade-relabel or upgrade-spoof attempts.

**Cross-language vectors.** Four new frozen vectors land alongside the preserved v4 / v3 / v2 fossils: `spec/vectors/lock-receipt-v5.json`, `execution-receipt-v4.json`, `execution-receipt-drand-only-v4.json`, `cross-receipt-linkage-v5.json`. Inputs reuse the existing v4 / v3 vector inputs verbatim — only `expected_schema_version` and `expected_payload_sha256` differ. Existing v4 / v3 / v2 vectors are preserved on disk verbatim; once pinned, frozen vectors are immutable. New `apps/wallop_core/test/wallop_core/vectors_regenerator_v5.exs` regenerates the new files; the existing `vectors_regenerator.exs` is unchanged and remains the regeneration tool for legacy vectors.

**Spec updates.** `spec/protocol.md` §4.2.1 enumerates the new schemas and the bundle-wrapper / receipt-version consistency rule. §4.2.4 expanded with the verifier mode taxonomy (attributable / attestable / self-consistency only), resolver failure semantics (terminal — no soft fallback), the verifier-side keyring-row consistency check, the `.well-known` pin file format, and the canonical `/operator/:slug/keys` response shape.

**What this does NOT change.** The HTML proof page continues to verify in the browser via the existing `verify_full_wasm` path because keys are passed to the WASM verifier from `OperatorInfo` (the receipts table) rather than read from the bundle wrapper. The static "local self-check only" mode badge stays accurate. A follow-up will switch the proof page to `verify_bundle_with_resolved_keys_wasm` so verification is genuinely resolver-driven; the static badge keeps reading correctly until then.

**Sequencing note.** `wallop_verifier 0.12.0` (which has the v5/v4 parser support, the `KeyResolver` trait, and the `BundleShape` consistency rule) was published to crates.io on 2026-04-28, before this commit. Third-party verifiers consuming the bundle JSON at `/proof/:id.json` need to be on `wallop_verifier ≥ 0.12.0` to verify v5/v4 bundles. The wallop_rs `vendor/wallop` submodule pointer was bumped to this branch's HEAD in wallop-verifier PR #38 to keep cross-language frozen-vector parity.

### wallop_web — proof page honestly discloses verifier mode

The `verify_block` component now renders an explicit "Mode: local self-check only" badge alongside the verify button, plus an expandable disclosure paragraph describing what the browser-side WASM check does and does not prove. Closes the §4.2.4 caveat-mode-without-disclosure gap visitors had been seeing — green ticks alone read as full verification, but the WASM verifier today runs in self-consistency mode (no out-of-band key resolution yet) and the disclosure now says so plainly.

The label and copy are static while the WASM verifier has only one constructable mode. When out-of-band key resolution lands and the verifier supports operator-hosted key pins ("attributable verification"), the badge becomes dynamic — the data attribute is in place; the JS side just needs a function that returns the active mode and an event that updates the badge text.

The disclosure paragraph: "the browser-side check confirms the bundle's signatures and math agree with each other and with the keys embedded in the bundle itself. It catches accidents and casual tampering, but it does *not* defend against a tampered mirror or a compromised CDN — an attacker serving a forged bundle with their own keys would also pass every step. Verification cryptographically tied to a specific operator identity becomes available in a future 1.x release once operators can publish key pins (see spec §4.2.4)."

One regression test in `proof_live_test.exs` covers the badge text and the caveat disclosure being present in the rendered HTML.

### wallop_core — defence-in-depth: assert keyring row consistency at sign time

New `WallopCore.Protocol.assert_key_consistency/3` helper re-derives the public key from the (Vault-decrypted) Ed25519 private key and asserts it matches the row's `public_key`, plus asserts `Protocol.key_id(public_key) == key_id`. Returns `:ok` or `{:error, :public_key_mismatch | :key_id_mismatch}`. Wired into all three signing paths immediately after the private-key decrypt step:

- `SignAndStoreReceipt` (operator-key signed lock receipts).
- `SignAndStoreExecutionReceipt` (infra-key signed execution receipts).
- `Transparency.AnchorWorker.sign_root/1` (infra-key signed transparency anchors).

Catches a corrupted in-memory key (e.g. truncated bytes after Vault decrypt), a row whose `key_id` column drifted out of sync with `public_key`, or a row whose `public_key` was rewritten without rotating `key_id`. Neither failure mode should be reachable through the existing Ash policy + DB trigger surface, but the check is cheap and runs on every sign — defence-in-depth alongside the keyring temporal binding CHECK constraint.

Anchor worker's `sign_root/1` refactored from nested `case` to a `with` chain (credo flagged the new nesting as too deep); each step now has its own `_or_log` helper preserving the existing per-failure log lines. Four new tests on the helper cover the consistent path, both mismatch errors, and function-clause guards on input sizes.

No behaviour change for production paths — every signing flow today produces consistent keyring rows; the helper is a no-op in those cases.

### wallop_web — `/operator/:slug/keys` surfaces `inserted_at` and `key_class`

Each entry in the keys array now includes `inserted_at` (RFC 3339 timestamp) and `key_class: "operator"`. Both fields are required by the spec §4.2.4 temporal binding rule (a verifier MUST reject when `key.inserted_at > receipt.binding_timestamp`), and `key_class` discriminates operator-class keys from infrastructure-class keys when a future verifier consumes both endpoints in the same resolution path.

Existing fields (`key_id`, `public_key_hex`, `valid_from`) are unchanged. Pure additive — existing consumers ignoring unknown JSON fields are unaffected.

Four tests added in `operator_controller_test.exs` (new file): 404 on unknown slug; fields present and well-formed; `inserted_at` and `valid_from` match the spec §4.2.1 canonical RFC 3339 form (`YYYY-MM-DDTHH:MM:SS.ssssssZ`, 27 bytes — guards against a future schema migration silently dropping microsecond precision and breaking downstream verifiers); `inserted_at` matches the keyring row append time within seconds of test setup.

### Spec — cross-draw transparency commitment (§4.2.7)

Documents the public-listing property at `/operator/:slug` as a normative spec commitment: every draw with a signed lock receipt MUST appear in the operator's public registry regardless of subsequent state (locked, awaiting_entropy, pending_entropy, completed, failed, expired); only `:open` working-state draws are excluded. The commitment defends against post-hoc draw shopping (lock → see result → discard → re-lock with same entries at the same sequence slot — the discarded slot stays publicly visible and the auditor can spot the gap).

This sits alongside the §4.2.6 transparency anchors as the public-listing complement to the anchor-based per-receipt tampering detection: anchors prove no receipt was retroactively altered or removed; the listing proves no sequence slot was ever quietly skipped. Six sub-rules pinned in §4.2.7: per-operator sequence numbers monotonically increasing with no gaps in the publicly listed (non-`:open`) subset (advisory-locked `MAX+1` at create time), every signed-lock-receipt draw publicly visible, `:open` draws excluded, sequence-slot immutability post-`:open` (the `prevent_draw_mutation` trigger already enforces this), lock-receipt persistence for the life of 1.x, and operator slug stability (the `operator_slug_immutability` trigger plus the slug appearing in every signed receipt's payload).

### wallop_web — `/operator/:slug` listing scopes to non-`:open` draws

Aligns the LiveView listing implementation with the §4.2.7 commitment. The base query gains `status != :open`, and the PubSub realtime update path drops broadcasts for `:open` draws so the two surfaces (initial paginated load + realtime updates) can't disagree. Three regression tests cover the property: locked draws appear, `:open` draws do not appear, PubSub updates for `:open` draws don't slip in.

No producer-side change; signed bytes and frozen vectors are untouched. Public listing now reflects the spec commitment exactly.

### wallop_web — regression test for public router surface

Two distinct surfaces can grow silently:

1. **Phoenix top-level routes** — adding a new `scope`, route, or `forward(...)` to `WallopWeb.Router` extends the public HTTP surface.
2. **AshJsonApi resource × action** — adding `json_api do` to any resource in `WallopCore.Domain` (or a new action inside an existing block) auto-mounts a new endpoint under the `forward("/", AshJsonApiRouter)` wildcard inside `/api/v1`. The Phoenix route table is invariant under this change, so a Phoenix-only allowlist would not catch it.

New regression test (`router_routes_test.exs`) pins both: Phoenix routes via `WallopWeb.Router.__routes__/0`, AshJsonApi routes via `AshJsonApi.Domain.Info.routes/1` + `AshJsonApi.Resource.Info.routes/1` as `{resource, action, method, path}` tuples (format-stable across AshJsonApi versions). Any addition or removal in either surface fails the test with a clear diff, forcing the contributor to update the allowlist intentionally rather than letting routes appear by accident.

The wildcard forward in the router gains an inline comment pointing at the test, so a reviewer following the wildcard lands on the tripwire.

No behaviour change. Existing routes unchanged.

### wallop_core — defence-in-depth: protect `operator_sequence` post-lock

The draw immutability trigger (`prevent_draw_mutation`) now forbids mutation of `operator_sequence` once status leaves `open`, alongside the existing `entry_hash` / `entry_canonical` protection. Closes a theoretical-but-currently-unreachable mutation window during the brief `locked → awaiting_entropy` transition: lock + sequence-assignment + receipt-signing all run inside one Ash transaction so the existing producer surface never exposed it, but any future code path that rewrites the column post-lock is now blocked at the storage layer.

No behaviour change for production paths. New regression test under `draw_immutability_test.exs` asserts the constraint via raw SQL.

### wallop_core — security: keyring temporal binding

Closes a keyring backdating attack vector. `OperatorSigningKey.create` and `InfrastructureSigningKey.create` are append-only at the Ash policy level (`forbid_if(always())`), but any code path running with `authorize?: false` (mix tasks, seeds, future admin endpoints, compromised admin credentials) could insert a row with arbitrary `valid_from`. `SignAndStoreReceipt` picks the "current" key via `valid_from <= now ORDER BY valid_from DESC LIMIT 1`, so a back-dated insert with `valid_from = '2020-01-01'` immediately becomes the selected signer at any current time — letting a malicious admin forge new receipts claiming historical `locked_at` times.

Two complementary mitigations land here. The producer-side change is a symmetric ±60 second `CHECK` constraint on `valid_from` vs `inserted_at` for both `operator_signing_keys` and `infrastructure_signing_keys` tables. Forward dating is rejected for the same reason backdating is — a 1.x append-only keyring should not have optionality around when a key starts being valid. The migration runs a pre-flight check on existing rows and aborts with the offending IDs if any current data violates the new constraint, so deployments with hand-written historical rows fail loudly rather than silently before the constraint attaches.

The verifier-side complement is documented in `spec/protocol.md` §4.2.4 as a new "Temporal binding to first-existence timestamp" rule. Each receipt class is checked against its own binding timestamp: lock receipt against `operator_signing_key.inserted_at`, execution receipt against `infrastructure_signing_key.inserted_at` against `executed_at`, transparency anchor against `inserted_at` against `anchored_at`. Per-receipt comparison (rather than always against `lock.locked_at`) preserves legitimate infrastructure-key rotation between lock and execute. The verifier-side comparison has no skew tolerance — both timestamps are operator-produced and committed, so any drift is signal not noise. Spec text also covers forward compatibility for a future `revoked_at` field (1.x verifiers MUST ignore unknown keyring columns; 1.y verifiers MUST apply the symmetric `revoked_at > binding_timestamp` rule).

The verifier-side enforcement and corresponding selftest scenarios (`signing_key_backdated_lock_receipt`, `signing_key_backdated_execution_receipt`, `signing_key_backdated_transparency_anchor`, plus boundary-equality and rotate-between-lock-and-execute positive guards) ship in a follow-up `wallop_verifier` release.

No signed-byte change. No schema bump. The `inserted_at` field becomes the third pillar of keyring semantics joining `signing_key_id` (F2) and the retention obligation (§4.4).

### Docs — MIGRATING.md restructured by consumer audience

`MIGRATING.md` previously read as if pitched at Hex package consumers, leaving HTTP API consumers unsure which sections applied. Restructured with a top-level "which sections apply to me?" table separating HTTP API consumers, Hex package consumers, and verifier consumers; version sections subdivided into `### HTTP API surface`, `### Hex package surface`, and `### Verifier surface` blocks.

The 0.15.x → 0.16.0 section is expanded from a one-line summary into a full HTTP-consumer guide covering the four code-affecting changes: capturing wallop-assigned UUIDs from the `add_entries` response (with the exact JSON path, field name, and order-guarantee contract); reading winning entries by `entry_id` in `GET /draws/:id` results after the completion webhook; the absence of server-side idempotency on `add_entries` retries (callers gate client-side; server-side idempotency-key support is post-1.0.0 roadmap); and removal of the `:execute` action surface.

No code change. No spec change. Documentation-only.

### Spec — cross-receipt field consistency (§4.2.5) and weather observation window

Documents two verifier obligations that close a splice-attack class named in the round 2 audit. These are spec requirements on verifiers; the Elixir producer already upholds them by construction (both receipts for a single draw read from the same underlying record).

**Cross-receipt field consistency.** Every field duplicated across the lock receipt and the execution receipt MUST be byte-identical. Without this check, an infrastructure-level attacker signing a fraudulent execution receipt can pair it with a legitimate lock receipt from a different draw, operator, or entropy window — `lock_receipt_hash` binds the lock bytes into the exec but does not bind the exec's own duplicated fields back to the lock. Cross-checked fields: `draw_id`, `operator_id`, `sequence`, `drand_chain`, `drand_round`, `weather_station`. Bundle envelope `draw_id` also cross-checked. Explicitly excluded: `signing_key_id` (different keys by design — operator vs infra), `operator_slug` (derivative of `operator_id`), algorithm identity tags (already validated per-receipt).

**Weather observation window.** The execution receipt's `weather_observation_time` MUST fall in `[lock.weather_time - 3600s, lock.weather_time]`. Bound direction reflects production behaviour — Met Office publishes observations at hour boundaries (`XX:00:00` UTC), and the entropy worker fetches the most recent observation at or before the declared target. Prevents an infrastructure-level attacker from fetching weather from any point in time and attributing it to the draw's declared window.

No signed-byte change. No schema bump. Enforcement ships in `wallop_verifier` 0.10.0.

### wallop_core — security / observability: redact identifiers from logs and telemetry

Addresses a side-channel leak flagged in the round 2 vulnerability audit. Entry UUIDs and draw UUIDs were previously emitted raw from entropy/webhook/expiry workers, the execution-receipt signing path, and the draw-entries controller — visible to anyone with access to `Logger` output or the OpenTelemetry span stream. Spec §4.3 forbids exactly this class of cross-run correlation vector.

Every affected call site now routes identifiers through `WallopCore.Log.redact_id/1`, which applies `HMAC-SHA-256(per-BEAM salt, id)` truncated to 5 bytes / 10 hex chars. The salt is regenerated on every BEAM restart, so intra-run log correlation is preserved for on-call debugging while cross-restart and cross-tape correlation is broken. Salt generation emits a `[:wallop_core, :log, :salt_generated]` telemetry event so mid-run resets are visible in metrics rather than silently decohering log lines.

A source-tree guard test (`log_leak_guard_test.exs`) fails CI if any new `Logger.*`, `:telemetry.execute`, or `Tracer.*` call interpolates an `*.id` / `*_id` variable without routing through the helper.

No signed-byte change. No schema bump. No frozen-vector change. Historical proof verifiability is untouched.

### wallop_core 0.17.0 — BREAKING: execution receipt schema v3 adds `signing_key_id`

Closes the last documented protocol-level hole before the 1.0.0 stability contract freeze.

#### What changes

- Execution receipt signed payload now commits `signing_key_id` — the 8-char hex fingerprint of the wallop infrastructure key that produced the signature. Schema version bumps `"2"` → `"3"`. Key set otherwise identical to v2.
- `Protocol.build_execution_receipt_payload/1` now requires `:signing_key_id` in its input map. Calls without it raise `FunctionClauseError` at the producer boundary.
- Frozen vectors for v3 are added alongside (`spec/vectors/execution-receipt-v3.json`, `spec/vectors/execution-receipt-drand-only-v3.json`). The existing v2 vector files are preserved as historical reference; verifiers that support both schemas exercise them against the v2 fixtures.
- Spec §2.6 updated with the new field; §4.2.1 bumps the frozen execution schema to `"3"` and documents dual-version support. §4.2 adds a categorical refusal paragraph: `signing_key_id` is the sole permitted key-identity field on receipts — fields describing key version, algorithm, issuance time, expiry, custodian, or provenance are out of scope for 1.x. §4.2 also spells out the anti-forgery binding (`lock_receipt_hash`) vs identity disambiguation (`signing_key_id`) distinction so future readers don't confuse the two. §4.3 "Open commitments before 1.0.0 final" is collapsed — F2 was its sole entry and is now resolved; §4.4 through §4.6 renumber accordingly. §4.4 Historical verifiability gains a keyring retention trust assumption: operators commit to retaining every infrastructure signing key used to sign any 1.x-era receipt, for the life of 1.x. Unresolvable `signing_key_id` on a historical receipt is rejected per §4.2.4.
- `wallop_verifier` v0.9.0 is required for consumers producing v3 receipts. v0.9.0 supports both v2 and v3 via exact-field-set `serde` deserialisation — `#[serde(deny_unknown_fields)]` on both struct shapes plus a required `signing_key_id` on v3 closes the downgrade/upgrade relabel attack by construction. A `parse_execution_receipt` dispatcher routes on `schema_version` and returns a terminal `UnknownSchemaVersion` error on anything outside `"2"` / `"3"` — verifiers MUST NOT retry on this error, they MUST upgrade.

#### What consumers need to do

Pin `wallop_verifier` to `>= 0.9.0`. Historical v0.16.x-era v2 receipts continue to verify under the v0.9.0 verifier. Any consumer that calls `Protocol.build_execution_receipt_payload/1` directly must now pass `signing_key_id`; the signing orchestrator inside `wallop_core` handles this automatically via the loaded infrastructure key.

#### What does not change

Lock receipt schema stays at v4. Transparency anchor envelope is unchanged. JCS canonicalisation, Ed25519 signing, drand BLS verification, `sha256-pairwise-v1` Merkle construction, and the `weather_fallback_reason` enum are all untouched. Cross-language frozen-vector parity for every pre-v3 vector is preserved byte-for-byte.

#### Why this is the last 1.0.0 blocker

Without `signing_key_id` on execution receipts, an infrastructure-key rotation would leave every historical execution receipt resolvable only by brute-forcing the infra keyring — the exact pattern §4.2.4 forbids for operator keys. Closing this brings the execution receipt to parity with the lock receipt and the transparency-anchor envelope, both of which already commit `signing_key_id` for their respective keys.

---

### wallop_core 0.16.0 — BREAKING: purge `operator_ref`, add UUID capture, receipt shape v4

Three bundled breaking changes that together close the pre-1.0.0 receipt-hardening pass:

1. Removes the operator-supplied `operator_ref` sidecar from `Entry` end-to-end.
2. Adds two HTTP capabilities so operators can capture wallop-assigned entry UUIDs at ingest time.
3. Tightens the receipt envelopes — lock receipt v3→v4, execution receipt v1→v2, algorithm identity tags pinned, `weather_fallback_reason` frozen as an enum, `:execute` action surface removed.

Callers that need `uuid ↔ their-own-id` mapping capture the returned UUIDs from the `add_entries` response (in submission order) and store the mapping in their own database. No operator-supplied reference data lives in wallop_core.

#### What changes — operator_ref purge

The `operator_ref` attribute, validation module, and `entries.operator_ref` column are removed. The `add_entries` action's `entries` argument shape becomes `[%{weight: pos_integer()}]` — the optional `ref` field is gone. `Entries.load_for_draw/1` returns `[%{uuid, weight}]`. `entry_hash` was already shape-invariant to `operator_ref` (extra keys on entries are ignored), so the canonical bytes are unchanged — the v0.15.0 frozen vectors replay green against v0.16.0 code.

#### What changes — entry UUID capture

`PATCH /api/v1/draws/:id/entries` now returns a response of the form `%{data: <draw>, meta: %{inserted_entries: [%{uuid}]}}`. The `inserted_entries` array preserves the submission order of the request's entries, so caller[i] ↔ uuid[i] correlation is server-authoritative and zero-round-trip. Transaction-atomic — partial batch failure rolls back the whole batch.

New `GET /api/v1/draws/:id/entries` endpoint. api_key-scoped, returns `{entries: [{uuid, weight}], next_after?: uuid}` sorted UUID-ascending, keyset-paginated via `?after=<uuid>&limit=<n>`. Works at any draw status (open, locked, terminal). At `:locked` status onward the response is byte-identical to the public `GET /proof/:id/entries`. Used for post-TTL recovery after a dropped response and as the canonical source for building the ticket manifest Merkle tree at lock time.

Entry UUIDs remain **server-generated UUIDv4 from `:crypto.strong_rand_bytes/1`**. Operator-supplied UUIDs are not accepted — low-entropy operator input would reintroduce the brute-force surface the v0.15.0 UUID refactor killed.

#### Migration

Run `mix ecto.migrate` to drop the `entries.operator_ref` column. If any row data matters (it shouldn't — the field was write-only at the API surface), back it up first.

Callers must stop sending `ref` on `add_entries`. The response now includes `meta.inserted_entries` with per-entry UUIDs in submission order. Capture the `(uuid ↔ your-reference)` mapping at submit time in your own encrypted-at-rest table. Use the new authenticated `GET /api/v1/draws/:id/entries` to recover UUIDs after a dropped response, or to read the canonical UUID-sorted set at lock time for manifest construction.

#### What changes — receipt shape v4 / execution v2

Lock receipt `schema_version` bumps `"3"` → `"4"`. Execution receipt's `"execution_schema_version"` key is renamed to `"schema_version"` (symmetric with lock) and value bumps `"1"` → `"2"`. Verifiers reject unknown schema versions — historical receipts remain verifiable with older verifier versions; new receipts require a v4/v2-aware verifier.

Both receipts now carry explicit algorithm identity tags inside the signed payload, so cryptographic choices are forensically anchored at commitment time:

- Both receipts add: `jcs_version: "sha256-jcs-v1"`, `signature_algorithm: "ed25519"`, `entropy_composition: "drand-quicknet+openmeteo-v1"`.
- Execution receipt also adds: `drand_signature_algorithm: "bls12_381_g2"`, `merkle_algorithm: "sha256-pairwise-v1"`.

Rotating any algorithm requires a new tag value plus a schema version bump. Existing `wallop_core_version` and `fair_pick_version` remain as forensic code-identity anchors.

**`weather_fallback_reason` is now a frozen enum**: `"station_down"`, `"stale"`, `"unreachable"`, or `null`. A new pure classifier at `WallopCore.Entropy.WeatherFallback.classify/1` maps raw weather-client errors to one of the four values (`:unreachable` is the catch-all). Receipt build raises on unknown values; verifier rejects unknown values. A fifth value requires a schema bump, not a minor addition.

**`Entries.load_for_draw/1` sorts `(inserted_at ASC, id ASC)`**. `entry_hash` bytes unchanged (the protocol layer sorts by UUID before any commitment) — this stabilises every other iteration site (proof bundle, FairPick input, webhook payload, PDF render) against Postgres row-order drift.

**Unreachable `:execute` action deleted**, along with the `NoEntropyDeclared` validation module and internal `ExecuteDraw` change. The `:locked` status enum value is retained (observers rely on it). If caller-seed lock-and-wait is ever wired up properly, it lands as a 1.x additive minor.

Zero-drift proof: `entry-hash.json`, `compute-seed.json`, `fair-pick.json`, `merkle-root.json`, `ed25519.json`, `key-id.json`, `anchor-root.json` are byte-identical to v0.15.0 vectors. A pinned regression test in `frozen_vectors_test.exs` asserts `entry_hash` byte equality — any accidental change to the canonical form breaks loudly.

---

### wallop_core 0.15.0 — BREAKING: entry identifier refactor

This release replaces operator-chosen entry IDs with wallop-assigned
UUIDs, adds an optional `operator_ref` sidecar, and rewrites the
`entry_hash` canonical form. Lock receipt schema bumps v2 → v3. Every
downstream consumer that reads entries, winners, or signed receipts
needs to update.

The previous scheme ("opaque operator IDs, masked on the public proof
page") was cryptographically incoherent — unsalted SHA-256 made
`entry_hash` brute-forceable against low-entropy IDs, and third
parties couldn't actually verify a draw without the raw entry list.
The new scheme publishes UUIDs + weights on the public proof page,
keeps any operator-supplied reference strings private, and binds the
`draw_id` into the hash to prevent cross-draw confusion.

#### Canonical form

`entry_hash = SHA-256(JCS({draw_id, entries: [{uuid, weight} sorted by uuid]}))`. All UUIDs must be lowercase, hyphenated, 36-char RFC 4122. Weights must be positive integers. Violations raise at the Protocol boundary.

**`operator_ref` is deliberately NOT committed in the hash.** It lives as an operator-private sidecar on the Entry resource, validated at ingest (≤ 64 bytes, no control codepoints U+0000–U+001F, U+007F, U+2028, U+2029), visible only to the operator via the authenticated entries endpoint, and never exposed on the public proof surface. The canonical form obeys a durable invariant: anything the hash commits must be derivable from the public ProofBundle bytes alone — so a third-party verifier can independently reproduce `entry_hash` without needing operator-only data. See `spec/protocol.md` §2.1 and the frozen vectors in `spec/vectors/entry-hash.json`.

#### Entry resource

The `entry_id` column is renamed to `operator_ref`, made nullable, and stripped of the old PII-reject regex and `(draw_id, entry_id)` unique index. The Ash primary key `id` is the public UUID — bound into `entry_hash`, returned in the API, published on the proof page. Entry rows remain immutable post-lock via the existing Postgres trigger.

#### Ingest API

`add_entries` now accepts `[%{ref, weight}]` (ref optional). The response includes the wallop-assigned UUID per entry, in submission order. Empty-string refs are normalised to nil in the `add_entries` ingest path; direct `Entry.create` calls (internal/test only, policy-forbidden in production) preserve the exact string. Either way, the canonical `entry_hash` treats nil and `""` refs identically — the key is omitted from the JCS payload. **Capture the `uuid ↔ your customer` mapping immediately from the submit response — wallop cannot reconstruct it later.** `remove_entry` now takes an `entry_uuid` argument. The batch-dedup check is removed; `operator_ref` uniqueness is the operator's problem.

#### Receipts

Lock receipt schema v3 — same 16 fields as v2, new `schema_version` value signals the new `entry_hash` canonical form. Verifiers reject unknown `schema_version` values rather than attempting to reconstruct an older shape. `wallop_core_version` in the signed payload is the forensic anchor if a future canonical form ever ships. Execution receipt schema unchanged; its `results` field now holds entry UUIDs (was operator IDs).

#### Public-verifier invariant

The canonical `entry_hash` deliberately commits only fields present byte-identically in the public ProofBundle. A regression test (`ProofBundleTest`, "bundle entries reproduce the committed entry_hash") ensures any future change preserves this: it builds a draw with a mix of entries with and without `operator_ref`, emits the public bundle, and asserts the bundle's entries (without access to `operator_ref`) reproduce the signed lock receipt's `entry_hash`. The other commitments in the protocol (`compute_seed`, lock/execution receipt payload SHA-256, `lock_receipt_hash`, transparency anchor `merkle_root`) were audited and all satisfy the same invariant — their hashed inputs appear byte-identically in the public artifacts.

#### Proof page / PDF

Entry-ID anonymisation is removed. `WinnerList`, PDF appendix, and proof bundle emit raw UUIDs. `operator_ref` is never rendered on any public surface. Any historical cached PDFs of locked draws will fail the fingerprint invariant on regeneration — **purge the PDF cache on deploy.**

#### Migrating

- Anyone reading `entry.entry_id` → `entry.operator_ref`.
- Anyone reading winners: `results[n]["entry_id"]` is now a UUID.
- Anyone submitting entries: send `%{ref: ..., weight: ...}`, store the returned `uuid` per entry alongside your own customer ID.
- External verifiers (the published Rust verifier crate + WASM bindings) must bump to 0.5.0 and implement the new canonical form.

### wallop_core

- **Pin AES-GCM IV length to 12 bytes.** Cloak defaults to 16 when `iv_length` is omitted, which differs from the NIST SP 800-38D recommendation of 96-bit (12-byte) IVs. Any service sharing the same database must use the same IV length — pinning it explicitly in all environments (dev, test, prod) prevents silent interop failures when decrypting at-rest signing keys and webhook secrets.
- **Explicit vault decrypt error handling.** `WebhookWorker` and `AnchorWorker` previously used bare pattern matches (`{:ok, decrypted} = Vault.decrypt(...)`) that crashed with `MatchError` on decrypt failure. Both now handle errors explicitly — webhook delivery routes to `{:cancel, :vault_decrypt_failed}` (permanent, not retried) and anchor signing logs the failing key_id.
- **Boot-time vault health check.** New `WallopCore.VaultHealthCheck.check!/1` performs an encrypt/decrypt round-trip on startup and refuses to boot if the vault is misconfigured. Distinguishes encrypt failure, decrypt failure, and round-trip mismatch with specific error messages. Wired into `WallopWeb.Application.start/2`.
- **Rename prod env var from `CLOAK_KEY` to `VAULT_KEY`** for consistency. Falls back to `CLOAK_KEY` for one deploy cycle.
- **Webhook on draw expiry.** `ExpiryWorker` now sends a webhook when a draw expires (open for 90+ days), matching the existing pattern for completed and failed draws. Integrators no longer need to poll to discover expired draws.
- **Authenticated `/api/v1/health` endpoint.** Returns `{"status": "ok"}` behind API-key auth. Useful for integrator liveness probes.

### wallop_web

- **Proof bundle endpoint.** New `GET /proof/:id.json` endpoint serves a canonical, JCS-encoded proof bundle for any completed draw. The bundle contains the entries, results, drand entropy + signature + chain hash, weather value (if present), both signed receipts, and both public keys — everything needed for offline verification with the wallop-verify CLI. Output is byte-equivalent to `spec/vectors/proof-bundle.json` and produced by the same `WallopCore.ProofBundle.build/1` function.
- **Download proof bundle button** on the proof page links directly to the new endpoint. Sits alongside the existing PDF certificate download.
- **Proof bundle controller now distinguishes corrupt-state failures from missing draws** — completed draws with broken proof chains return 500 with `proof_chain_incomplete` instead of masquerading as 404, mirroring the visible warning the operator panel surfaces for the same condition.
- **LiveView proof page refreshes lock receipt assign** on the lock and completion transitions of `maybe_reveal/2`. A user watching a draw lock + complete in real time previously ended up with `@receipt = nil` from mount and saw a spurious "commitment receipt missing" warning after the reveal animation.

### wallop_core

- **`WallopCore.ProofBundle.build/1`** — single producer for proof bundle JSON, used by both the test vector generator and the live HTTP endpoint. Cannot drift because both consumers share the same function.
- **Bundle bytes are deterministic.** Entries are sorted by id and results are sorted by position before serialization, so repeated calls for the same draw return byte-equal output. Third-party verifiers caching bundle hashes depend on this contract.
- **New `proof-bundle-drand-only.json` frozen vector** — a reference for the weather-omitted bundle shape, the most likely cross-implementation divergence point.

### wallop_verifier 0.4.0

Rust crate renamed from `wallop_rs` to `wallop_verifier` (v0.4.0); browser verifier and test-vector docs updated to match. The new name reflects the crate's actual scope — independent protocol verification — rather than a generic "Rust port of wallop" framing.

### wallop_rs 0.3.0

**Breaking:** `verify_full_wasm` no longer accepts a `count` parameter. Winner count is now extracted from the signed lock receipt after signature verification, closing a trust gap where a caller could pass a different count than what was committed at lock time.

### wallop_rs 0.2.0

New WASM exports for third-party verification:
- `verify_full_wasm` — full end-to-end draw verification (entries → hash → seed → results → receipt signatures)
- `verify_receipt_wasm` — Ed25519 signature verification for lock and execution receipts
- `key_id_wasm` — key fingerprint derivation from public key hex
- `lock_receipt_hash_wasm` — SHA-256 hash of lock receipt payload (for chain linkage verification)
- `build_receipt_payload_wasm` — reconstruct lock receipt canonical payload
- `build_execution_receipt_payload_wasm` — reconstruct execution receipt canonical payload
- `receipt_schema_version_wasm` — extract schema version from receipt payload
- `merkle_root_wasm` — Merkle root computation for transparency log verification
- `anchor_root_wasm` — anchor root computation (combined operator + execution receipt trees)

### wallop_web

- **Full client-side verification pipeline.** The proof page "Verify independently" button now runs an 11-step animated verification: independently compute entry hash and seed, rerun the draw, verify lock and execution receipt Ed25519 signatures, check binding between receipts and computed values (entry hash, seed, results), verify lock_receipt_hash chain linkage, and run a final `verify_full_wasm` double-check. All computation happens in the visitor's browser via the wallop_rs WASM module — no server round-trip.
- **Extract shared verify block component.** The duplicated verification UI between the static proof controller and LiveView proof page is now a single shared component (`VerifyBlock`).

### wallop_core 0.14.1

- **Deploy safety: Oban Lifeline plugin.** Rescues entropy worker jobs stuck in "executing" state after a node restart (deploy, crash). Without this, a deploy that kills a worker mid-execution left the Oban job orphaned and the draw stuck in `pending_entropy` forever. `rescue_after: 2 minutes`.
- **Worker timeout.** EntropyWorker now has an explicit 90-second timeout. Prevents hung workers from running indefinitely and racing with Lifeline rescue.
- **Execution exhaustion → mark_failed.** When entropy fetching succeeds but draw execution fails (e.g. receipt signing error), the draw is now marked as `failed` after max retries instead of staying in `pending_entropy` forever.
- **Lifeline race tolerance.** `fail_draw_with_reason` now handles the case where a draw has already been completed by a concurrent worker (Lifeline rescue race). Returns `:ok` instead of a false error.

### 🚨 BREAKING — wallop_core 0.14.0

- **Draw creation now rejects API keys without an operator.** Previously, creating a draw with an operator-less API key silently succeeded but produced no cryptographic attestation (no lock receipt, no execution receipt, no proof chain). This is now a hard validation error. All silent-skip paths in receipt signing and operator sequence assignment are now hard failures. **Consumer action required:** ensure every API key used for draw creation has an `operator_id` set.

### wallop_core 0.13.2

- **Execution receipt endpoints** — two new public endpoints for third-party verifiers:
  - `GET /operator/:slug/executions` — list execution receipts for an operator (ETag on max sequence, 60s cache)
  - `GET /operator/:slug/executions/:n` — single execution receipt by sequence number (immutable cache, `max-age=31536000`)

  Response shape mirrors operator receipt endpoints: decoded payload, base64 JCS bytes, base64 signature. Verifiers can fetch the payload and signature, then verify independently using the infrastructure public key from `GET /infrastructure/key`.

### wallop_core 0.13.1

- **Transparency log: dual sub-trees + infrastructure signature** — `AnchorWorker` now builds separate Merkle roots for operator receipts and execution receipts, combined with RFC 6962 domain separation: `anchor_root = SHA256("wallop-anchor-v1" || operator_receipts_root || execution_receipts_root)`. The combined root is signed by the infrastructure Ed25519 key, making the transparency log itself infra-key-signed. A verifier who only cares about one receipt type can verify their sub-tree independently. New columns on `transparency_anchors`: `operator_receipts_root`, `execution_receipts_root`, `execution_receipt_count`, `infrastructure_signature`, `signing_key_id`. Existing anchors (pre-this-version) have null values for the new columns.

### wallop_core 0.13.0

- **Execution receipts** — every completed draw belonging to an operator now gets a second signed artefact: an execution receipt signed by the wallop infrastructure Ed25519 key (not the operator's key). The signed payload commits to entropy values (drand randomness, drand BLS signature, weather value), the computed seed, the results, algorithm versions (`wallop_core_version`, `fair_pick_version`), and a `lock_receipt_hash` linking it cryptographically to the lock-time operator receipt. Together, the two receipts let a verifier confirm both halves of the commit-reveal protocol using only signed bytes and public external data.

  New resources:
  - `WallopCore.Resources.ExecutionReceipt` — append-only, one per draw, DB trigger enforced
  - `WallopCore.Resources.InfrastructureSigningKey` — wallop-wide Ed25519 keypair, append-only, Vault-encrypted

  New protocol function:
  - `Protocol.build_execution_receipt_payload/1` — 20-field maximalist signed surface, `execution_schema_version: "1"`

  New endpoints:
  - `GET /infrastructure/key` — raw 32-byte Ed25519 public key with `x-wallop-key-id` header

  New mix tasks:
  - `mix wallop.bootstrap_infrastructure_key` — one-time first-deploy setup
  - `mix wallop.rotate_infrastructure_key` — annual rotation

  **Consumer action required:** if your app parses or displays receipts, you can now fetch and verify execution receipts alongside lock receipts. No changes required for existing lock receipt handling — this is purely additive.

- **PubSub unnamed-node fallback** — `WallopCore.Application` now checks `Node.alive?()` before starting PubSub with the Redis adapter. Unnamed nodes (e.g. one-off mix tasks) fall back to local PubSub instead of crashing.

### 🚨 BREAKING — wallop_core 0.12.0

- **Lock receipt schema v2.** `Protocol.build_receipt_payload/1` now requires seven additional fields and the function's pattern match has changed — callers passing the old 8-key map will get a `FunctionClauseError`. `@receipt_schema_version` bumped from `"1"` to `"2"`.

  New fields in the signed JCS payload:

  | Field | Why |
  |---|---|
  | `winner_count` | Outcome-determining. Was trigger-frozen but not cryptographically committed. |
  | `drand_chain` | Declared entropy source, known at lock time. |
  | `drand_round` | Declared entropy source, known at lock time. |
  | `weather_station` | Declared entropy source, known at lock time. |
  | `weather_time` | Declared entropy source, known at lock time. |
  | `wallop_core_version` | Algorithm version pinning — records which wallop_core ran the draw. |
  | `fair_pick_version` | Carried separately because `mix deps.update fair_pick` can change it independently. |

  Old v1 receipts remain valid. `schema_version` in the payload lets verifiers pick the right parser.

  **Consumer action required:** if your code calls `Protocol.build_receipt_payload/1` directly (unlikely — it's normally called internally by `SignAndStoreReceipt`), add the seven new fields. If your code parses receipt payloads (e.g. for display or verification), handle both `schema_version: "1"` and `schema_version: "2"` shapes.

### 🚨 BREAKING — wallop_core 0.11.0

- **Sandbox draws are now a separate resource** (`WallopCore.Resources.SandboxDraw`) with their own table (`sandbox_draws`), own primary key, no foreign key to `draws`, no `operator_sequence`, no `OperatorReceipt`, and no transparency log membership. Sandbox draws are structurally incapable of being confused with real draws at the schema level. See PR that lands this for the full rationale — short version: the previous design had `execute_sandbox` as an update action on `Draw` gated only by a runtime config flag, the `seed_source` column could be set to `'sandbox'` post-lock, and the signed operator receipt did NOT commit to `seed_source`. Any consumer of `wallop_core` that set `allow_sandbox_execution: true` in its prod config could divert a real locked draw to sandbox execution before the entropy worker ran, with nothing cryptographic to contradict a later claim of "that was only a test." This is now a structural impossibility.
- **Removed from `Draw`:** the `execute_sandbox` update action, its change module (`WallopCore.Resources.Draw.Changes.ExecuteSandbox`), and the `:sandbox` value from the `seed_source` `one_of` constraint (now `[:caller, :entropy]`).
- **Removed from config:** `config :wallop_core, :allow_sandbox_execution` — the action it gated no longer exists.
- **Immutability trigger rewritten:** the `awaiting_entropy → completed` transition is now forbidden entirely. The previous sandbox carve-out is gone. Any row attempting `seed_source = 'sandbox'` is also rejected at the trigger level, belt-and-braces against direct SQL.
- **Migration drops any existing sandbox rows from `draws`** — pre-launch, no real data to preserve. Bypasses the trigger via `session_replication_role = 'replica'` since sandbox rows are typically in terminal state.

#### Migration guide for consumers of wallop_core

1. Bump your `wallop_core` dep to `0.11.0` (git tag).
2. Search your codebase for `Draw.execute_sandbox`, `:execute_sandbox`, or `seed_source: :sandbox` — all three are now gone.
3. Replace the create-lock-execute-sandbox flow with a single `SandboxDraw.create` call:
   ```elixir
   WallopCore.Resources.SandboxDraw
   |> Ash.Changeset.for_create(:create, %{
        name: "My test run",
        winner_count: 3,
        entries: [%{"id" => "ticket-1", "weight" => 1}, ...]
      }, actor: api_key)
   |> Ash.create!()
   ```
   Sandbox draws are create-and-execute in one transaction — no separate lock or execute step.
4. If your app reads sandbox draws separately from real draws, update UI/admin code to query `SandboxDraw` instead of `Draw`. The two resources share no rows, no FKs, no sequence space.
5. Drop any `allow_sandbox_execution` config entries from your `config.exs` / `runtime.exs` files — the key is unused.
6. If your app shows sandbox draws on any public or operator-facing page, consider removing them entirely. Sandbox draws never belong on the real `operator_sequence` registry (`/op/:slug`); real-draw lineage must not be able to accidentally leak sandbox data.
7. Run `mix ash.codegen` in your own repo if you need to generate a migration for any downstream changes. The `sandbox_draws` table is created by wallop_core's own migration and requires no consumer-side schema work.

#### Rate limiting

- Sandbox draws do **not** increment `ApiKey.monthly_draw_count`, do **not** consume monthly tier quota, and are **not** covered by `WallopWeb.Plugs.TierLimit` (which applies to real `Draw` HTTP routes only). Consumers exposing sandbox draws via their own HTTP API should apply their own rate limit — sandbox create-and-execute runs `fair_pick` synchronously on the request path with no entropy wait, making it the cheapest DoS surface in the system if left unprotected. The telemetry event below is the observability hook.

#### Telemetry

- New event: `[:wallop_core, :sandbox_draw, :create]`, measurements `%{count: 1, entry_count: n}`, metadata `%{api_key_id, operator_id, winner_count}`. Sandbox draws are unaudited by design (no receipt, no transparency log), so this event is the only way to observe abuse or unusual volume — attach it to Honeycomb or your alerting pipeline.

### Added

- **Proof PDF embedded fingerprint** — every proof PDF now carries a canonical `proof.json` file embedded as a PDF attachment. The JSON contains the full verifiable record of the draw (`draw_id`, `entry_hash`, `seed`, `drand_*`, `weather_*`, `winners`, signed operator receipt, schema version, template revision, generated timestamp). JCS-canonical (RFC 8785) via the same `Jcs.encode/1` code path used by the operator receipt commitment.
- A third party with only the PDF bytes can extract `proof.json` (e.g. `qpdf --show-attachment=proof.json file.pdf`), parse it, and independently verify the draw against the public receipt log without trusting the rendered HTML inside the PDF. The PDF becomes a self-contained cryptographic artifact, not just a presentation document.
- New `WallopWeb.ProofPdf.Fingerprint` module — pure, no DB or IO. Builds the canonical map and provides `compare/2` for the regeneration invariant.
- **Regeneration invariant**: when regenerating a PDF for an existing draw, the new fingerprint must match the previously-stored sidecar on every field except `template_revision` and `generated_at`. If anything else has drifted (entry hash, seed, winners, receipt) the regeneration is refused with a clear error and a log line listing the drifting fields. Layout-only changes don't trigger this; data drift always does.
- `WallopWeb.ProofStorage` gains `put_metadata/2` and `get_metadata/1` callbacks. Both backends (filesystem and S3) store the canonical fingerprint as a sidecar file (`<draw_id>.json`) next to the PDF.
- `qpdf` installed in the wallop runtime Docker image (~5MB) — used to attach `proof.json` to the Gotenberg-rendered PDF via a one-shot `System.cmd/3` call.
- Frozen test vector for the canonical JSON encoding so any future change to the fingerprint shape breaks loudly.

- **Proof PDF** — certificate-style downloadable proof artifact for completed draws at `GET /proof/:id/pdf`. Rendered from a dedicated HEEx template with print-specific CSS, POSTed as HTML to a sidecar Gotenberg service (https://gotenberg.dev — headless Chromium wrapped in a stateless HTTP API, deployed as a separate process), returned as PDF bytes. Contains a certificate front page (logo, title, operator, summary, hashes), a verification chain (drand + weather + seed + signed operator receipt), a full anonymised entries appendix, and a verification recipe. Lazy-generated on first request, cached via a pluggable storage backend (filesystem in dev, S3-compatible in production — configured via `AWS_S3_BUCKET_NAME` and friends), served with `Cache-Control: public, max-age=31536000, immutable`.
- `WallopWeb.ProofStorage` behaviour with `Filesystem` and `S3` backends. The S3 backend works against any S3-compatible endpoint (AWS S3, Cloudflare R2, MinIO, etc.).
- "Download PDF certificate" button on terminal proof pages (both the live LiveView and the cached static renderer).
- `eqrcode`, `ex_aws`, `ex_aws_s3`, `hackney`, `sweet_xml` deps on wallop_web. No Chromium in the wallop image — that lives in the sibling Gotenberg service.
- In-progress draws (open / locked / awaiting_entropy / pending_entropy) return 404 with a clear "PDF is only available once the draw has completed" message.
- Tests cover: filesystem storage round-trip, controller 404 for unknown draw, controller 404 for in-progress draw, controller serves cached bytes with the right headers for terminal draws. Tests pre-populate the cache so they never hit Gotenberg.

### Deployment notes

- Deploy `gotenberg/gotenberg:8` as a sidecar service alongside the wallop service
- **Keep Gotenberg off any public network** — it has no built-in auth; reach it on an internal network only
- Set `GOTENBERG_URL` on the wallop service to the Gotenberg internal URL (port 3000 by default)
- For local dev: `docker run --rm -p 3000:3000 gotenberg/gotenberg:8`, defaults to `http://localhost:3000`

### Notes

- The PDF inherits the live proof page's entry anonymisation pattern (first character + mask). Both are scheduled to be removed in the entry identifier refactor — until then, the PDF matches what's on screen.
- QR code linking back to the live proof page is a stretch goal, not in this iteration.
- Pre-generation on draw completion (via an Oban job) is also stretch; current behaviour is lazy.

## [0.10.0] - 2026-04-07

### Added

- `ash_paper_trail` extension on `Operator` resource — every change to an operator (create, `update_name`, future mutations) is automatically captured as a row in the new `operators_versions` table. Stores the action name, action inputs, the changes themselves, and the timestamp. Configured in `:changes_only` mode so each version only stores the diff, not a full snapshot.
- `WallopCore.Resources.Operator.Version` Ash resource (auto-derived by `ash_paper_trail`) for querying the version history idiomatically. Added to `WallopCore.Domain`.
- Migration `create_operators_versions` adds the `operators_versions` table with `version_source_id` FK to `operators`, action metadata columns, and a `changes` jsonb column.
- Tests covering create-emits-version, update-emits-version, and rejected-update-does-not-emit-version.

### Notes

- `Operator.update_name` now has `require_atomic? false` because the validation can't be expressed as an atomic SQL update. Functionally identical, slightly less efficient — fine because name changes are rare.
- Consuming apps that maintain their own ad-hoc audit table for operator changes (e.g. `operator_name_changes`) can stop writing new rows after upgrading to 0.10.0 and migrate to querying `Operator.Version` instead. The wallop_core history is the canonical source going forward.

## [0.9.1] - 2026-04-07

### Added

- `WallopCore.DrawPubSub` helper that broadcasts `{:draw_updated, draw}` to both the per-draw topic (`draw:<id>`) and the per-operator topic (`operator:<operator_id>`). All Draw change modules now use this helper instead of calling `Phoenix.PubSub.broadcast` directly. The operator topic broadcast is skipped when the draw has no operator (backward compatible).
- `BroadcastUpdate` change wired into `Draw.create`, `execute_with_entropy`, `execute_drand_only`, and `mark_failed` actions. Previously these actions had no broadcast at all, so the operator registry page never saw new draws or terminal state transitions in real time.

### Fixed

- Operator registry page now updates live when draws are created or change state, instead of staying static until refresh. Consuming apps that pinned `wallop_core ~> 0.9.0` will only get this fix after bumping to `~> 0.9.1`, since v0.9.0 was tagged before the live-update wiring was added.

## [0.9.0] - 2026-04-07

### Added

- **Operator registry** — closes the cross-draw verifiability gap (post-hoc draw shopping: lock → see result → discard → re-lock). Each `Operator` (created by the consuming app or `mix wallop.gen.operator` for self-hosters) gets a public `/operator/:slug` page listing every draw they have ever locked, including discarded and expired ones, with gap-free per-operator sequence numbers. Does not defend against locking parallel draws with different entry sets — operators must follow "one contest = one locked draw"
- `Operator`, `OperatorSigningKey`, `OperatorReceipt`, `TransparencyAnchor` Ash resources
- `Operator.slug` is the canonical identity (immutable, citext, embedded in every signed receipt). `Operator.name` is a mutable display label only, never embedded in any signed payload
- Nullable `operator_id` on `ApiKey` (backward compatible — keys with no operator behave exactly as before)
- Nullable `operator_id` and `operator_sequence` on `Draw`, assigned at create time inside an advisory-locked transaction (gap-free; Postgres sequences explicitly avoided so rollbacks don't leak gaps)
- **Signed commitment receipts** — every locked draw belonging to an operator gets an Ed25519-signed JCS payload (`commitment_hash`, `entry_hash`, `sequence`, `signing_key_id`, `schema_version`, `locked_at`, ...) inserted into `operator_receipts` in the same transaction as `lock`. Failure to sign rolls back the lock — no sequence is burned. Signing keys are Cloak-encrypted via `WallopCore.Vault`; rotation is append-only via additional `OperatorSigningKey` rows with later `valid_from` timestamps
- `Protocol.build_receipt_payload/1`, `sign_receipt/2`, `verify_receipt/3`, `key_id/1`, and `merkle_root/1` (RFC 6962-style). Frozen test vector for the signing path
- **Transparency log** — daily Oban cron worker (`Transparency.AnchorWorker`, runs at 03:30 UTC) builds a Merkle root over all receipts since the previous anchor and pins it to a drand round number. Listed at `/transparency`
- `OperatorController` JSON endpoints under `/operator/:slug`: `receipts`, `receipts/:n`, `keys`, `key` — append-only, cacheable, with ETag on the index and immutable cache on individual receipts
- Proof page now shows "Draw #N by [Operator] (@slug →)" linking to the public registry, plus an expandable signed-receipt panel with the JCS payload, signature, and signing-key id. Renders on both the live and cached static proof pages
- Public registry LiveView with keyset pagination, intersection-observer infinite scroll, debounced case-insensitive search, and a card layout on mobile
- `mix wallop.gen.operator SLUG NAME` — generates an operator and its first Ed25519 keypair, prints the key fingerprint to publish out-of-band
- Append-only PG triggers on `operator_signing_keys`, `operator_receipts`, and `transparency_anchors`
- `(operator_id, operator_sequence)` and `(operator_id, sequence)` unique indexes as belt-and-braces backstops
- Slug denylist, length cap, and Unicode validation on operator name (NFC-normalised, rejects control chars, ZW chars, BOM, line/para separators, bidi overrides, and the tag block) to defend against homograph/spoofing attacks
- Marketing site at `/` with hero, "Why provable?", organiser/developer split, tabbed protocol explainer, origin story, FAQ, and waitlist CTA

## [0.8.0] - 2026-04-07

### Added

- API key tier metadata: `tier`, `monthly_draw_limit`, `monthly_draw_count`, `count_reset_at` (set by consuming apps via `update_tier` action)
- `WallopWeb.Plugs.TierLimit` — enforces monthly draw limit on `POST /api/v1/draws`, returns 429 with tier name and upgrade URL when exceeded
- `WallopWeb.Plugs.KeyRateLimit` — per-API-key rate limit (60 requests/minute, ETS-based), returns 429 with `Retry-After` header
- `IncrementApiKeyDrawCount` change — bumps the actor's monthly_draw_count on successful draw create, auto-resets if `count_reset_at` is in the past
- `increment_draw_count`, `reset_draw_count`, `update_tier` internal actions on `ApiKey`

### Notes

- Per-IP rate limit (`WallopWeb.Plugs.RateLimit`) still runs before auth to protect bcrypt CPU
- Tier metadata is null by default (unlimited) — consuming apps must populate via `update_tier` for paid tiers

## [0.7.0] - 2026-04-03

### Added

- drand relay failover — tries 4 relays (api.drand.sh, drand.cloudflare.com, api2.drand.sh, api3.drand.sh) on transport/5xx errors
- drand-only fallback — if weather is unavailable after 5 attempts, draws proceed with drand entropy only instead of failing
- `weather_fallback_reason` field on draws — stores why weather was skipped, part of the immutable proof record
- `execute_drand_only` Ash action — separate from `execute_with_entropy`, requires fallback reason
- `Protocol.compute_seed/2` — drand-only seed computation (weather_value key omitted from JCS, not null)
- Live retry feedback on proof page — shows attempt count, source status, and drand-only fallback in progress
- Proof chain and timeline show fallback reason for drand-only draws

### Changed

- Retry backoff flattened: 15s, 30s, 45s, 60s, 90s for first 5 attempts, then 120s. Total window ~14 minutes.
- Removed 2-hour failure timeout — Oban's max_attempts (10) handles termination
- EntropyWorker uses `DrandClient.fetch_with_failover/2` instead of `fetch/2`

## [0.6.3] - 2026-04-02

### Added

- Startup warning if a consuming app uses the default Oban prefix — catches the misconfiguration that causes job queue conflicts
- Boundary test enforcing wallop_core has zero references to WallopWeb or WallopApp modules — prevents accidental coupling in future PRs

## [0.6.2] - 2026-04-02

### Fixed

- Add `:inets` to `extra_applications` — fixes OTel exporter startup warning in releases

### Changed

- Document Oban prefix separation for consuming apps — apps sharing the database must use a different Oban prefix to avoid competing for draw jobs (see README)

## [0.6.1] - 2026-04-01

### Fixed

- Draws no longer wait up to 70 minutes for weather observation — removed redundant "observation must be after draw creation" check that rejected valid pre-lock observations. The "within 1 hour of declared weather_time" check is sufficient.

### Changed

- Weather delay reduced from 10 minutes to jittered 3-5 minutes — drand only needs ~30 seconds, no reason to wait longer
- Entropy worker spans now include `draw.weather_time`, `draw.status`, `entropy.weather_observation_time` attributes for debugging
- OTel context propagated into Task.async calls so drand/weather fetch spans appear as children in traces, not orphaned
- Waitlist signup: `WaitlistSignup` Ash resource with `citext` unique email, wired to LiveView form
- Mobile hamburger nav with LiveView toggle
- Anime.js smooth scroll easing for anchor links

## [0.6.0] - 2026-03-31

### Fixed

- **Weather observation pinned to declared time** — WeatherClient now accepts a `target_time` parameter and selects the reading closest to (but not after) the draw's declared `weather_time`, within a 1-hour window. Previously, retries could silently use a different hour's observation, breaking independent verifiability.
- **ExecuteWithEntropy validates observation proximity** — rejects weather observations more than 1 hour from the declared `weather_time`

### Changed

- **Failure timeout reduced from 24h to 2h** — drand resolves in seconds and weather within an hour; 24h was excessive
- **Permanent errors fail immediately** — 401/403 from entropy APIs and invalid responses now fail the draw instantly instead of retrying for hours
- **Oban attempt tracking works correctly** — switched from `{:snooze, _}` (which bypassed attempt counting) to `{:error, _}` with Oban's built-in exponential backoff. `max_attempts` reduced from 20 to 10.
- **Backoff uses Oban's built-in mechanism** — exponential backoff (~30s, ~60s, ~2m, ~4m, ~8m, capped at 15m) instead of custom `compute_backoff` using draw creation time

## [0.5.2] - 2026-03-31

### Added

- Custom OTel spans in Oban workers: entropy collection (drand/weather fetches with source attributes), draw execution, webhook delivery status, expiry candidate counts
- Timestamps on completed proof page timeline stages (full datetime, with fallback to `inserted_at`/`executed_at` for older draws)

### Changed

- Proof page pulse animation: circles now pulse outward repeatedly instead of breathing in and out
- Ecto telemetry handler filters out Oban internal polling queries (`oban_jobs`, `oban_peers`, `oban_producers`)

## [0.5.1] - 2026-03-31

### Fixed

- PubSub broadcasts for all draw state changes: declare_entropy, execute_draw, execute_sandbox, expire, and update_name now push live updates to proof pages and dashboards

## [0.5.0] - 2026-03-31

### Added

- OpenTelemetry instrumentation: Oban job tracing, Ash action tracing, Ecto query spans, Phoenix/Bandit HTTP request spans
- OTLP export to Honeycomb via `HONEYCOMB_API_KEY` env var (auto-creates `wallop` dataset)
- Oban plugin tracing disabled to avoid polling noise — only job lifecycle events are traced

## [0.4.2] - 2026-03-31

### Fixed

- PubSub config: consuming apps can provide full PubSub config via `config :wallop_core, :pubsub` for Redis adapter support

### Added

- Redis PubSub adapter for cross-node live draw updates (`REDIS_URL` or `:pubsub` config)

## [0.4.1] - 2026-03-31

### Changed

- Entry operations use Ash API instead of raw Ecto queries (AddEntries, RemoveEntry, Proof, Entries)
- Duplicate entry detection now returns `Ash.Error.Invalid` instead of `Ash.Error.Unknown`

### Added

- API documentation for Entry resource attributes (entry_id PII warning, weight range)
- Description for `entry_count` on Draw
- `citext` Postgres extension

## [0.4.0] - 2026-03-31

### Changed

- **Breaking:** Entries moved from JSONB column to dedicated `entries` table — `entries` attribute removed from Draw, replaced by `entry_count`
- Draw responses include `entry_count` instead of full entries array
- `Proof.check_entry` uses indexed lookup instead of linear scan

### Added

- Direct entry check link: `/proof/:draw_id/:entry_id` auto-checks and pre-fills the entry on page load
- Entries table with immutability trigger (entries locked when draw leaves `open` status)

## [0.3.2] - 2026-03-30

### Added

- Sandbox execution: `execute_sandbox` action with published, deterministic seed (`SHA-256("wallop-sandbox")`) for integration testing
- `seed_source: :sandbox` enum value — honestly labels sandbox draws as non-random
- Proof page banners: purple "Sandbox draw" banner and amber "Not a verified draw" banner for `:caller` seed source

### Changed

- Internal actions (`transition_to_pending`, `execute_with_entropy`, `mark_failed`) now `forbid_if(always())` — prevents external callers from racing the entropy worker with fabricated entropy values

### Removed

- `create_manual` action — all draws now go through the full `create → add_entries → lock` flow with entropy declaration

## [0.3.1] - 2026-03-28

### Fixed

- PubSub registry crash in Oban workers — moved PubSub from `wallop_web` to `wallop_core` to fix cross-app dependency that caused `unknown registry: WallopWeb.PubSub` errors

### Changed

- Webhook delivery now retries transient failures (5xx, network errors) up to 5 attempts with exponential backoff. Permanent failures (4xx, missing draw) are cancelled immediately.

## [0.3.0] - 2026-03-27

### Added

- Optional `name` field on draws (max 255 chars). May be set at creation or updated while the draw is `open`; locked once the draw is locked.
- OpenAPI spec served at `GET /api/open_api` (JSON) and Redoc docs UI at `GET /api/docs`
- Static `priv/openapi.json` committed to the repo; CI verifies it stays in sync via `mix wallop.gen.openapi`
- `mix wallop.gen.openapi` task to regenerate the spec
- Attribute descriptions and GDPR/PII warning in the OpenAPI spec
- Bearer auth security scheme in the OpenAPI spec
- Staged reveal animation on proof page when draw completes (~10 second sequence)
- Dev-only reveal demo page at `/dev/reveal-demo` for visual testing

## [0.2.0] - 2026-03-26

### Added

- Public proof pages at `/proof/:id` with real-time LiveView updates
- Vertical timeline showing draw progress (entries locked → entropy → winners)
- Verification-first completed view with proof chain and external links
- Entry anonymisation (first character + fixed mask)
- Entry self-check form
- Server-side re-verify button
- Tailwind CSS + daisyUI styling
- Countdown timer on proof page during "Fetching Entropy" stage (daisyUI countdown + JS hook)
- 30-second poll loop on proof page as PubSub safety net for reliable real-time updates
- Phoenix LiveDashboard with Obanalyze at `/dev/dashboard` (dev only)
- dotenvy `.env` file support for dev/test configuration
- PubSub broadcasts from EntropyWorker for live updates
- Automatic entropy fetching: drand beacon + Met Office weather observations
- Draw state machine expanded: locked → awaiting_entropy → pending_entropy → completed/failed
- EntropyWorker (Oban): parallel entropy fetch, seed computation, automatic draw execution
- WebhookWorker (Oban): HMAC-SHA256 signed delivery to callback URLs
- DrandClient: HTTP client for drand randomness beacon with chain hash validation
- WeatherClient: Met Office Land Observations client with Decimal pressure normalization
- Callback URL SSRF protection (HTTPS only, no private IPs)
- Lock time entropy declarations (drand round + weather time computed at draw creation)
- Caller-provided seed blocked when entropy sources are declared (Ash + DB trigger)
- 24-hour failure timeout with automatic transition to failed state
- Webhook secret on ApiKey (generated alongside API key)
- Entry structure validation with bounds (max 10k entries, max weight 1000)
- Open draw state: draws accept entries over time before locking (breaking API change)
- `POST /draws/:id/entries` — batch add entries to open draw
- `PATCH /draws/:id/lock` — lock entries and start entropy collection
- Stage 0 "Entries Open" in proof page timeline with live entry counter
- Open draw view on proof page
- Expired draw view on proof page
- ExpiryWorker: hourly Oban cron job expires open draws after 90 days
- `stage_timestamps` field records when each stage transition occurred
- PubSub broadcasts on entry add/remove for real-time proof page updates

### Changed

- Weather entropy: fetch latest available observation instead of exact declared hour
- Weather entropy: reduce wait time from next whole hour (~60 min) to 10 minutes
- Draw schema: new `weather_observation_time` field records actual observation used
- Draw lifecycle: new `open` state replaces one-shot create (breaking API change)
- Draw creation no longer accepts entries — use add_entries + lock flow
- New `expired` terminal state for abandoned open draws (90-day timeout)
- Immutability trigger rewritten: protects `failed`/`expired` states, `winner_count` unconditionally
- Updated mix task output to show webhook secret

## [0.1.0] - 2026-03-24

### Added

- Elixir umbrella project structure (`wallop_core`, `wallop_web`)
- `WallopCore.Protocol.entry_hash/1` — entry list hashing per protocol spec §2.1
- `WallopCore.Protocol.compute_seed/3` — seed computation from entropy sources per protocol spec §2.3
- Protocol test vectors P-1, P-2, P-3 (frozen, canonical)
- GitHub Actions CI (format, credo, tests)
