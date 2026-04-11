# Shared Frozen Test Vectors

Protocol commitment vectors in JSON format. Both wallop_core (Elixir)
and wallop_verifier (Rust) load these files and verify identical outputs.

If any vector changes, both implementations must update simultaneously.
A divergence means the protocol is ambiguous.

## Consumer update policy

These vectors are consumed by external repos via git submodule:

- **fair_pick_rs** — Rust crate
- **wallop_verifier** — Rust WASM verifier
- **fair_pick** — Elixir hex package

When vectors change in this repo, all consumer repos must update their
submodule pin before their next release. Corrective vector changes
(bug fixes, not just new coverage) are especially urgent — a stale pin
means the consumer's tests pass but the implementation may not match
the current protocol.

## Files

- `entry-hash.json` — entry_hash canonicalization + SHA-256
- `compute-seed.json` — seed derivation (drand+weather, drand-only)
- `fair-pick.json` — FairPick.draw algorithm outputs
- `ed25519.json` — signing + verification with RFC 8032 test keypair
- `lock-receipt.json` — lock receipt JCS payload (schema v2)
- `execution-receipt.json` — execution receipt JCS payload (schema v1)
- `execution-receipt-drand-only.json` — drand-only receipt (null weather fields)
- `end-to-end.json` — full pipeline: entries → hash → seed → winners
- `anchor-root.json` — dual sub-tree combined root
- `cross-receipt-linkage.json` — lock receipt → SHA-256 → execution receipt hash chain
- `key-id.json` — key fingerprint derivation
- `merkle-root.json` — RFC 6962 Merkle tree
