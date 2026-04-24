# Migrating

Upgrade notes for `wallop_core` consumers. Listed newest-first. Each section is self-contained — follow every section between your current version and the target.

---

## 0.16.x → 0.17.0

### What changed

The execution receipt's signed JCS payload now commits `signing_key_id` — the 8-char hex fingerprint of the wallop infrastructure signing key that produced the signature. Schema version bumps `"2"` → `"3"`. The lock receipt (schema v4) and the transparency anchor envelope (schema v1) are unchanged.

Why: without `signing_key_id` on the execution receipt, rotating the infrastructure key would leave historical execution receipts resolvable only by brute-forcing the keyring — the exact pattern that `spec/protocol.md` §4.2.4 forbids for operator keys. Closing this brings the execution receipt to parity with the lock receipt and the transparency anchor, both of which already commit `signing_key_id` for their respective keys. See `spec/protocol.md` §4.2 for the anti-forgery binding (`lock_receipt_hash`) vs identity disambiguation (`signing_key_id`) distinction and the categorical refusal paragraph that freezes `signing_key_id` as the sole permitted key-identity field on receipts.

### What you need to do

**1. Pin `wallop_verifier` to a version that supports v3.**

`wallop_verifier` 0.9.0 and above understand both `"2"` and `"3"` execution receipts. Pin the Rust crate, WASM package, and / or CLI to `>= 0.9.0`. Earlier versions will reject v3 receipts with `UnknownSchemaVersion`.

**2. No API shape changes unless you call the producer directly.**

If you embed `wallop_core` as an Elixir dependency and call `WallopCore.Protocol.build_execution_receipt_payload/1` directly, the input map now requires a `:signing_key_id` key. Calls without it raise `FunctionClauseError` at the producer boundary. The orchestrator inside `wallop_core` handles this automatically via the loaded infrastructure key — no change required if you only consume the public HTTP surface.

HTTP APIs, webhook payloads, proof bundle shape, and receipt endpoints are byte-compatible on every field other than the execution receipt's signed payload — which gains `signing_key_id` and bumps `schema_version` to `"3"`.

**3. Historical verifiability is preserved.**

Execution receipts signed under wallop_core 0.16.x (schema `"2"`) remain verifiable for the life of the 1.x series. A verifier at `wallop_verifier >= 0.9.0` dispatches on `schema_version` and routes to the v2 or v3 parser by exact field set. Both versions share the same signature verification and cross-receipt linkage logic.

### Verifier behaviour details

`wallop_verifier >= 0.9.0` enforces the following by construction via `#[serde(deny_unknown_fields)]`:

- A payload declaring `schema_version: "2"` with a `signing_key_id` field rejects as a downgrade-relabel attempt.
- A payload declaring `schema_version: "3"` without a `signing_key_id` field rejects as an upgrade-spoof attempt.
- Any `schema_version` other than `"2"` or `"3"` returns `UnknownSchemaVersion` — this is terminal. Callers MUST NOT retry on this error; they MUST upgrade the verifier.

### Operational commitment

`spec/protocol.md` §4.4 documents an operational commitment that the wallop operator retains every infrastructure signing key used to sign any 1.x-era execution receipt or transparency anchor, for the duration of 1.x. A key that is rotated remains in the keyring (marked `revoked_at`), not removed. A verifier encountering an unresolvable `signing_key_id` on a historical receipt MUST reject per §4.2.4.

---

## Earlier versions

- **0.15.x → 0.16.0** — `operator_ref` purged from the entry shape; entry identifiers are now wallop-assigned UUIDs captured from the `add_entries` response (`meta.inserted_entries`) or the authenticated `GET /api/v1/draws/:id/entries` endpoint. Lock receipt bumped v3 → v4 (algorithm identity tags pinned, `weather_fallback_reason` frozen as an enum, `:execute` action surface removed). Execution receipt bumped v1 → v2.
