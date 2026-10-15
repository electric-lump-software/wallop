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

### End-to-end

- `end-to-end.json` — full pipeline: entries → hash → seed → winners
- `proof-bundle.json` — full public proof bundle shape (the `/proof/:id.json` envelope)
- `proof-bundle-drand-only.json` — proof bundle for the drand-only path (no `weather_value`)

### Tampering

- `proof-bundle-v6-tamper.json` — lock v6 / execution v5 proof bundles on a real quicknet round, each with exactly one signed field changed and re-signed with the vector key (a changed lock also gets a recomputed, re-signed `lock_receipt_hash`), so only the semantic checks can refuse it. Shape: `{description, keys, bases: [{name, bundle, expected_passed: true}], cases: [{name, base, receipt, field, mutation, bundle, expected_failing_steps}]}`. `keys` is `[{key_id, public_key_hex, key_class, inserted_at}]`; each `bundle` is the bundle's JCS text. Every case must fail exactly its `expected_failing_steps` (snake_case step names) and never pass; the bases pass every step. Regenerate with `MIX_ENV=test mix run apps/wallop_core/test/wallop_core/tamper_vectors_generator.exs`.

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
