# Migrating

Upgrade notes for `wallop_core` consumers. Listed newest-first. Each section is self-contained — follow every section between your current version and the target.

## Which sections apply to me?

`wallop_core` has two integration surfaces, with different upgrade implications. Identify your consumer type before reading any version section.

| Consumer type | Description | Sections that apply |
|---|---|---|
| **HTTP API consumer** | You call `wallop_core` over its HTTP API (`POST /api/v1/draws`, `PATCH /draws/:id/entries`, etc.) and consume webhooks. You don't depend on the `wallop_core` Hex package. (e.g. PAM, third-party integrators.) | "HTTP API surface" subsection only. |
| **Hex package consumer** | You include `wallop_core` as an Elixir dependency in your `mix.exs` and call its modules directly. (e.g. `wallop-app`.) | Both "HTTP API surface" and "Hex package surface" subsections — Hex consumers see everything HTTP consumers see, plus the Elixir-level changes. |
| **Verifier consumer** | You run `wallop_verifier` (Rust crate, WASM package, or CLI) to verify proof bundles. May or may not also be an HTTP / Hex consumer. | "Verifier surface" subsection. |

Within each version section below, look for the `### HTTP API surface`, `### Hex package surface`, and `### Verifier surface` headings. If a section is absent for your consumer type, that version had nothing breaking on that surface — no action needed.

---

## 0.16.x → 0.17.0

### Why this release exists

The execution receipt's signed JCS payload now commits `signing_key_id` — the 8-char hex fingerprint of the wallop infrastructure signing key that produced the signature. Schema version bumps `"2"` → `"3"`. The lock receipt (schema v4) and the transparency anchor envelope (schema v1) are unchanged.

Without `signing_key_id` on the execution receipt, rotating the infrastructure key would leave historical execution receipts resolvable only by brute-forcing the keyring — the exact pattern that `spec/protocol.md` §4.2.4 forbids for operator keys. Closing this brings the execution receipt to parity with the lock receipt and the transparency anchor, both of which already commit `signing_key_id` for their respective keys. See `spec/protocol.md` §4.2 for the anti-forgery binding (`lock_receipt_hash`) vs identity disambiguation (`signing_key_id`) distinction.

### HTTP API surface

**No breaking changes for HTTP consumers.** HTTP endpoints, webhook payloads, proof bundle shape, and receipt endpoints are byte-compatible on every field other than the execution receipt's signed payload — which gains `signing_key_id` and bumps `schema_version` to `"3"`.

If your JSON parsing is non-strict (ignores unknown keys), you don't need to do anything. If you have a strict schema validator that rejects unknown fields on the execution receipt JSON, update it to accept the v3 shape (`signing_key_id` added; everything else unchanged).

### Hex package surface

If you embed `wallop_core` as an Elixir dependency and call `WallopCore.Protocol.build_execution_receipt_payload/1` directly, the input map now requires a `:signing_key_id` key. Calls without it raise `FunctionClauseError` at the producer boundary.

The orchestrator inside `wallop_core` handles this automatically via the loaded infrastructure key — **no change required if your code only goes through public Ash actions or the HTTP surface.** The breakage only affects callers who hand-build receipt payloads.

### Verifier surface

**1. Pin `wallop_verifier` to `>= 0.9.0`.**

`wallop_verifier` 0.9.0 and above understand both `"2"` and `"3"` execution receipts. Pin the Rust crate, WASM package, and / or CLI to `>= 0.9.0`. Earlier versions reject v3 receipts with `UnknownSchemaVersion`.

**2. Historical verifiability is preserved.**

Execution receipts signed under wallop_core 0.16.x (schema `"2"`) remain verifiable for the life of the 1.x series. A verifier at `wallop_verifier >= 0.9.0` dispatches on `schema_version` and routes to the v2 or v3 parser by exact field set. Both versions share the same signature verification and cross-receipt linkage logic.

**3. Verifier behaviour details.**

`wallop_verifier >= 0.9.0` enforces the following by construction via `#[serde(deny_unknown_fields)]`:

- A payload declaring `schema_version: "2"` with a `signing_key_id` field rejects as a downgrade-relabel attempt.
- A payload declaring `schema_version: "3"` without a `signing_key_id` field rejects as an upgrade-spoof attempt.
- Any `schema_version` other than `"2"` or `"3"` returns `UnknownSchemaVersion` — this is terminal. Callers MUST NOT retry on this error; they MUST upgrade the verifier.

**4. Operational commitment.**

`spec/protocol.md` §4.4 documents an operational commitment that the wallop operator retains every infrastructure signing key used to sign any 1.x-era execution receipt or transparency anchor, for the duration of 1.x. A key that is rotated remains in the keyring (marked `revoked_at`), not removed. A verifier encountering an unresolvable `signing_key_id` on a historical receipt MUST reject per §4.2.4.

**5. Browser-side verifier (WASM).**

The WASM bundle served from `/assets/wasm/` is updated in lockstep with the wallop_core release. When you deploy 0.17.0, returning visitors may have the 0.16.x bundle cached. A hard refresh (Cmd+Shift+R / Ctrl+Shift+R) clears it; no protocol concern — an older cached bundle fails on v3 receipts with an `UnknownSchemaVersion`-style error, which is the same terminal-reject behaviour any 0.8.x Rust verifier would produce.

---

## 0.15.x → 0.16.0

### Why this release exists

Two unrelated cleanups landed together:

1. **`operator_ref` purged from the entry shape.** Entry identifiers are now wallop-assigned UUIDs captured from the `add_entries` response. Previously, entries carried an operator-supplied reference string the operator used to map back to their own records. That field has been removed entirely; the operator captures the wallop-assigned UUID at insert time and holds the mapping themselves. (Reasoning in `docs/decisions/0003-entry-uuid-capture.md`.)
2. **Lock receipt v3 → v4.** Algorithm identity tags pinned (the picker algorithm and seed-derivation algorithm names are now committed in the receipt), `weather_fallback_reason` frozen as an enum (no free-form strings), and the `:execute` action surface removed in favour of automatic execution after entropy gathering.
3. **Execution receipt v1 → v2** (carries the algorithm pins forward).

### HTTP API surface

**This is the upgrade that requires actual code changes for HTTP consumers.** Non-trivial.

#### 1. Capture wallop UUIDs from the `add_entries` response

Your existing `PATCH /api/v1/draws/:id/entries` request shape is *fine* — wallop silently ignores any `id` field you include and assigns a fresh UUID per entry. **You are not broken at request time.** What changed is that the response now contains the UUIDs you must capture.

Response shape (top-level `meta`, not under `data.meta`):

```json
{
  "data": {
    "id": "<draw-uuid>",
    "type": "draw",
    "attributes": {
      "status": "open",
      "entry_count": 3
    }
  },
  "meta": {
    "inserted_entries": [
      {"uuid": "<wallop-uuid-1>"},
      {"uuid": "<wallop-uuid-2>"},
      {"uuid": "<wallop-uuid-3>"}
    ]
  }
}
```

`meta.inserted_entries[i].uuid` is the wallop UUID of the i-th entry you submitted. Field name is literally `"uuid"`, top-level `meta`, not `data.meta`.

**Order is committed-to as a 1.x contract.** UUIDs in `meta.inserted_entries` are returned in submission order — `meta.inserted_entries[i]` corresponds to `request.entries[i]`. Implementation pre-generates UUIDs in Elixir before insertion specifically so the contract is tautological rather than relying on database insertion order. Documented at `apps/wallop_core/lib/wallop_core/resources/draw/changes/add_entries.ex`. Safe to zip.

You **must** store the mapping `(your-id ↔ wallop-uuid)` on your side at insert time. wallop_core does not retain `operator_ref` and cannot resolve a query of "what's the wallop UUID for my-ticket-#42?" There is no recovery path for this mapping later — capture it at insert time or accept that you can't link your records back to wallop entries.

You can also recover all UUIDs for a draw via authenticated `GET /api/v1/draws/:id/entries`, but that returns wallop UUIDs only — it can't tell you which UUID corresponds to which of your records.

#### 2. Read winning entries by `entry_id` in draw results

Webhook payloads are intentionally minimal — `{draw_id, status}` plus `failure_reason` on `:failed`. The webhook does **not** carry winners.

After receiving a completion webhook, fetch full results via `GET /api/v1/draws/:id`. The `results` array on the draw uses field name **`entry_id`** (not `uuid`):

```json
"results": [
  {"position": 1, "entry_id": "<wallop-uuid>"},
  {"position": 2, "entry_id": "<wallop-uuid>"}
]
```

Map each `entry_id` back through your stored mapping to recover your record.

#### 3. `add_entries` is NOT idempotent on retry

If you POST `add_entries` and the HTTP response is lost (network blip, your worker crashes mid-flight), retrying the same request **will create fresh entries with fresh UUIDs.** wallop_core has no idempotency-key handling and no dedupe based on entry contents. The previous unique constraint on `(draw_id, entry_id)` was dropped when `operator_ref` was purged.

You must gate retries client-side. Practical pattern: track which `add_entries` requests have been issued (e.g. an idempotency token in your own DB), treat any post-success retry as a no-op rather than re-firing.

A server-side idempotency-key header is on the post-1.0.0 roadmap but is not in 0.16/0.17. Plan around the client-side gate.

#### 4. Lock receipt schema v4 — algorithm pins and weather enum

If you parse lock receipts on your side: schema_version bumps from `"3"` to `"4"`. Two new fields commit:

- `picker_algorithm: "fair_pick_v1"` — name of the deterministic winner selection algorithm.
- `seed_derivation: "bls_drand_round_signature_blake3"` (or similar) — name of the seed-derivation algorithm.

Plus `weather_fallback_reason` is now a frozen enum (atoms: `:on_time`, `:stale_observation`, `:fetch_failure`, `:disabled` — emitted as JSON strings). Prior free-form strings are gone.

If your code branches on `weather_fallback_reason` string contents, audit those branches against the enum.

#### 5. The `:execute` action is gone

`POST /api/v1/draws/:id/execute` no longer exists. Draws auto-execute when entropy is ready. If your client polled or POSTed to that endpoint, remove that code path; just wait for the completion webhook (or poll `GET /draws/:id` for `status`).

### Hex package surface

If you embed `wallop_core` as an Elixir dependency:

- `WallopCore.Resources.Draw` — the `:execute` action is removed.
- The `operator_ref` field on `WallopCore.Resources.Entry` is removed; the Entry schema no longer has it. Any code reading `entry.operator_ref` breaks at compile or run time.
- Lock and execution receipt builders in `WallopCore.Protocol` accept new arguments for the algorithm pins. Hand-built calls need updating; the orchestrator handles it for code going through Ash actions.

### Verifier surface

Pin `wallop_verifier >= 0.8.0` to understand v4 lock receipts and v2 execution receipts. Earlier verifier versions reject these as `UnknownSchemaVersion`.

---

## Earlier versions

Pre-0.15 versions are not documented here. If you are upgrading from earlier than 0.15, please file an issue and we'll write the section.
