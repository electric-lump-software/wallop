# Shared Frozen Test Vectors

Protocol commitment vectors in JSON format. Both wallop_core (Elixir)
and wallop_verifier (Rust) load these files and verify identical outputs.

If any vector changes, both implementations must update simultaneously.
A divergence means the protocol is ambiguous.

## Consumer update policy

These vectors are consumed by external repos via git submodule:

- **fair_pick_rs** — Rust crate
- **wallop_verifier** — Rust (native + WASM) verifier
- **fair_pick** — Elixir hex package

When vectors change in this repo, all consumer repos must update their
submodule pin before their next release. Corrective vector changes
(bug fixes, not just new coverage) are especially urgent — a stale pin
means the consumer's tests pass but the implementation may not match
the current protocol.

## Files

### Algorithm and canonicalisation

- `entry-hash.json` — `entry_hash` canonicalisation + SHA-256 (binds `draw_id` into the hash, entries shaped as `{uuid, weight}`)
- `compute-seed.json` — seed derivation (drand+weather, drand-only)
- `fair-pick.json` — `FairPick.draw` algorithm outputs
- `ed25519.json` — Ed25519 signing + verification with RFC 8032 test keypair
- `key-id.json` — 4-byte SHA-256 fingerprint derivation

### Receipts

- `lock-receipt.json` — lock receipt JCS payload (schema v4)
- `execution-receipt.json` — execution receipt JCS payload (schema v2, historical — v0.16.x-era receipts)
- `execution-receipt-drand-only.json` — v2 drand-only receipt with null weather fields
- `execution-receipt-v3.json` — execution receipt JCS payload (schema v3, current — adds `signing_key_id` for the infrastructure signing key)
- `execution-receipt-drand-only-v3.json` — v3 drand-only receipt with null weather fields
- `cross-receipt-linkage.json` — lock receipt → SHA-256 → `lock_receipt_hash` chain

### Entropy grammars

- `freq-window-v1.json` — the grid-frequency window rule (tag `drand-quicknet+elexon-freq-v1`): raw Elexon FREQ bodies and the `freq_value` of the window at `freq_start`, or `invalid` with the first failing reason (and reading time). Shape: `{description, rules, freq_start, cases: [{name, body, value} | {name, body, invalid: {reason, at?}}]}`; `body` is the response text, its rows are `body.data`, and every number is read from its JSON text. Covers the row rule (non-objects ignored; every matching object row counts, so a row with no `frequency` invalidates the window or makes it a duplicate), exact-text timestamps (`...T19:55:00.000Z` matches nothing), repeated keys (a key twice in one object, at any depth, makes the body invalid with reason `duplicate_key` and no `at`: a top-level `data` twice, and a row with two `frequency` or two `measurementTime` keys), the bounds, the number grammar and stuck runs of 5 and 6. A verifier must refuse every `invalid` case; the reason is core's.

### Schedules

- `schedule-boundaries-v1.json` — v6 draw schedules for both entropy tags, from a reference implementation written independently of core. `landobs` and `freq` hold every whole-minute `draw_at` from 22:00 to 02:59 UTC across seven windows (`window`): the end and start of UK summer time (2026-10-24/25, 2027-03-27/28), a month end, a year end, February 2027 (no leap day) and both sides of 29 February 2028. `landobs_grid_seconds` and `freq_grid_seconds` add the off-minute quicknet grid points 23:59:03–23:59:57 and 00:30:03–00:30:57 of each window. Each landobs case gives `round`, `weather_time`, `fetch_deadline` and `latest_lock_at`; each freq case gives `round`, `freq_start`, `fetch_deadline` and `latest_lock_at`. Times are UTC, whole seconds, `YYYY-MM-DDTHH:MM:SSZ`. `landobs_w30_not_w40` is a draw whose `weather_time` differs between W = 30 min and W = 40 min. Every implementation's schedule functions must match every case.

### End-to-end

- `end-to-end.json` — full pipeline: entries → hash → seed → winners
- `proof-bundle.json` — full public proof bundle shape (the `/proof/:id.json` envelope)
- `proof-bundle-drand-only.json` — proof bundle for the drand-only path (no `weather_value`)

### Tampering

- `proof-bundle-v6-tamper.json` — lock v6 / execution v5 proof bundles on a real quicknet round, each with exactly one signed field changed and re-signed with the vector key (a changed lock also gets a recomputed, re-signed `lock_receipt_hash`), so only the semantic checks can refuse it. Shape: `{description, keys, bases: [{name, bundle, expected_passed: true}], cases: [{name, base, receipt, field, mutation, bundle, expected_failing_steps}]}`. `keys` is `[{key_id, public_key_hex, key_class, inserted_at}]`; each `bundle` is the bundle's JCS text. Every case must fail exactly its `expected_failing_steps` (snake_case step names) and never pass; the bases pass every step. Regenerate with `MIX_ENV=test mix run apps/wallop_core/test/wallop_core/tamper_vectors_generator.exs`.
- `proof-bundle-v6-tamper-freq.json` — the same shape and rules under the grid-frequency tag `drand-quicknet+elexon-freq-v1`: bases `freq_observed` and `freq_fallback` on the same round (window start 19:54:00 UTC), and `freq_*` cases for the tag's own fields (`freq_start`, `freq_value`, `freq_fallback_reason`), the weather fields that must stay null, the tags on either receipt, and the shared fields. The same generator writes both files; one file per tag, so adding a tag never changes another tag's bytes.

  - `receipt` is `lock`, `exec` or `both`. A `both` case sets the same field on both receipts (for example a `fair_pick` version that was never released).
  - The `expected_failing_steps` are the verifier's own step names, and each set is pinned by running the verifier. Renaming or splitting a verifier step means regenerating this file.
  - Both receipts sign the `fair_pick_version` of the `fair_pick` dependency core runs, never a hard-coded string. The verifier accepts only `fair_pick` versions on its known list, so that version must be on the list. Core pins `fair_pick` exactly; moving to a new release means adding it to the verifier's list in the same release.

### Merkle and transparency anchors

- `merkle-root.json` — Merkle construction `sha256-pairwise-v1` (0x00 leaf prefix, 0x01 node prefix, Bitcoin-style odd-level duplication, empty-list sentinel `SHA-256(<<>>)`)
- `anchor-root.json` — dual sub-tree combined root (`SHA-256("wallop-anchor-v1" || op_root || exec_root)`)

### Keyring pin

- `pin/v1/valid.json` — signed keyring pin (§4.2.4): JCS pre-image, 14-byte domain separator (`wallop-pin-v1\n`), Ed25519 signature, and a one-byte-mutation negative case

### Key rotation

- `key-rotation-bidirectional.json` — operator key rotation (§4.2.4): two deterministic keypairs with non-overlapping active windows, two lock-receipt v5 payloads each signed by its corresponding key, and four cross-key verification cases (historical-receipt-with-original-key passes; new-receipt-with-new-key passes; both wrong-key cases fail). Pins `key_id` derivation byte-for-byte across implementations.
