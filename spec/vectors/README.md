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

### Merkle and transparency anchors

- `merkle-root.json` — Merkle construction `sha256-pairwise-v1` (0x00 leaf prefix, 0x01 node prefix, Bitcoin-style odd-level duplication, empty-list sentinel `SHA-256(<<>>)`)
- `anchor-root.json` — dual sub-tree combined root (`SHA-256("wallop-anchor-v1" || op_root || exec_root)`)
