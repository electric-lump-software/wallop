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

2026-10-26: `lock-receipt*.json`, `cross-receipt-linkage*.json` and `proof-bundle*.json` were regenerated (corrective) so every committed `drand_round` publishes after `locked_at`, and proof bundles carry real quicknet beacons. Consumers must bump their pin. The drand-only execution receipt vectors (`execution-receipt-drand-only*.json`) are unchanged frozen fossils on round 12345; their `lock_receipt_hash` (`3fbacc9e…`) is the hash of the linkage lock as it stood with `drand_round` 12345 (kept in `apps/wallop_core/test/fixtures/v5_builder_regression/cross-receipt-linkage.json`), not of the regenerated `cross-receipt-linkage.json`.

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
- `proof-bundle.json` — full public proof bundle shape (the `/proof/:id.json` envelope): lock receipt schema 5, execution receipt schema 4, on quicknet round 33068202 with its real beacon. No inline keys: the receipts are signed by the deterministic vector keys (seeds `sha256("wallop-vector-operator-key")` and `sha256("wallop-vector-infrastructure-key")`, the keys listed in the v6 bundle vectors), resolved by `signing_key_id`. The weather value is not a real reading.
- `proof-bundle-drand-only.json` — the same for the drand-only path (no `weather_value`)

### Observation weather (lock v6 / exec v5, `drand-quicknet+metoffice-landobs-v1`)

Under this tag an execution receipt is in exactly one of three states, and the seed follows the state it signs:

| State | `weather_value`, `weather_observation_time` | `weather_fallback_reason` | `freq_value` | `freq_fallback_reason` | Seed |
|---|---|---|---|---|---|
| (a) weather | set | null | null | null | `compute_seed(entry_hash, drand_randomness, weather_value)` |
| (b) grid frequency | null | `no_observation_by_deadline` | set | null | `compute_freq_seed(entry_hash, drand_randomness, freq_value)` |
| (c) drand only | null | `no_observation_by_deadline` | null | `no_frequency_by_deadline` | `compute_seed(entry_hash, drand_randomness)` |

`weather_station` is `wmo-03749` (Middle Wallop) in all three. The vectors pin how a verifier checks a receipt in each state. Which state a real draw ends in depends on what wallop had stored by the deadlines; that is a trust assumption, and no vector can prove an observation or a window was unavailable. Files whose name contains `-freq-window` are this tag's state (b), not the grid-frequency tag. Each file's `description` starts with the tag and, for receipts and bundles, the state.

- `weather-schedule-landobs-v1.json` — the draw schedule. Shape: `{description, entropy_composition, stations, w_secs, publish_margin_secs, lock_offset_secs, cases: [{drand_round, published_at, weather_time, latest_lock_at, freq_start}]}`. Cases: the round exactly at the bound (`published_at` = `weather_time` + `w_secs` + `publish_margin_secs`), the round before it, mid-hour rounds, and a round whose `weather_time` differs between W = 30 min and W = 40 min. Timestamps are canonical (six fractional digits).
- `weather-value-landobs-v1.json` — the `weather_value` grammar and bounds, and how a Land Observations row becomes a value. Shape: `{description, bounds, valid: [{value, t, mslp, rh, vis}], invalid: [{value, reason}], from_row: [{row, expected_value} | {row, expected_error: true}]}`. Each `row` keeps its numbers' exact JSON text (`60.0` and `60`, exponents, `1e400` in a field the grammar never reads), so read this file with a parser that keeps number text; a float-based JSON parser does not test the grammar. An f64-only JSON reader may refuse the whole file (`1e400`); that is intended, so read it typed, keeping each row field as raw text (for example serde_json `RawValue`). The rows are synthetic, in the documented Land Observations format.
- `lock-receipt-v6.json` — the lock receipt, schema 6, 20 fields. Shape: `{description, expected_field_count, expected_schema_version, expected_payload_sha256, payload_jcs, input}`; `input` is the builder input.
- `execution-receipt-v5.json`, `execution-receipt-freq-window-v5.json`, `execution-receipt-fallback-v5.json` — the execution receipt, schema 5, 28 fields, in states (a), (b) and (c). Same shape.
- `proof-bundle-v6.json`, `proof-bundle-v6-freq-window.json`, `proof-bundle-v6-fallback.json` — passing proof bundles for states (a), (b) and (c), built from the receipt vectors on quicknet round 33068212 with its real beacon. Shape: `{description, bundle, keys, expected_passed: true}`; `bundle` is the bundle's JCS text and `keys` is `[{key_id, public_key_hex, key_class, inserted_at}]`. Every verifier step must pass.

### Grid frequency (lock v6 / exec v5, `drand-quicknet+elexon-freq-v1`)

- `frequency-schedule-elexon-v1.json` — the draw schedule. Shape: `{description, entropy_composition, readings, spacing_secs, w_freq_secs, margin_secs, lock_gap_secs, stuck_run, bounds_mhz, cases: [{drand_round, published_at, freq_start, fetch_deadline, latest_lock_at}]}`.
- `frequency-value-elexon-v1.json` — the `freq_value` grammar, the reading rule and the window rule. Shape: `{description, bounds_mhz, stuck_run, valid, invalid: [{value, reason}], readings: [{text, expected_mhz} | {text, expected_error: true}], from_rows: [{freq_start, rows: [[measurementTime, frequency_text]], expected_value} | {freq_start, rows, expected_error: true}]}`. `text` and `frequency_text` are raw JSON text. `valid` and `from_rows` pin the stuck-run threshold from both sides.
- `lock-receipt-v6-freq.json` — the lock receipt, schema 6, 20 fields; `weather_station` and `weather_time` null.
- `execution-receipt-v5-freq.json`, `execution-receipt-fallback-v5-freq.json` — the execution receipt, schema 5, 28 fields, with a `freq_value`, and with `freq_fallback_reason` `no_frequency_by_deadline`. Every weather field is null.
- `proof-bundle-v6-freq.json`, `proof-bundle-v6-freq-fallback.json` — passing proof bundles for both, same shape as the observation-weather bundles. Every verifier step must pass.

Contains BMRS data © Elexon Limited copyright and database right 2026.

### Negative bundles (both v6 tags)

- `proof-bundle-v6-negative.json` — lock v6 / execution v5 bundles that must fail. Shape: `{description, keys, cases: [{name, bundle, expected_failing_steps}]}`. Each case changes signed fields of a passing bundle and signs again with the vector keys (a changed lock also gets a recomputed, re-signed `lock_receipt_hash`), and the seed, results and unsigned `entropy` are rebuilt from the changed execution receipt, so the signatures are valid over the bytes as written. Cases that change only a wrapper key or the unsigned `entropy` are not re-signed. `expected_failing_steps` is the exact set of steps that fail (snake_case step names, order-insensitive); every other step passes or is skipped. For a tag pair with no seed rule (mismatched or unknown tags), the seed and winner steps are skipped, never passed. The cases cover both tags: schedule and lock-time rules, stations, the three-state table (every single-field step away from each state), value grammars, tags and schemas, inline keys and drand timing.

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

## Third-party data

Some vectors embed real readings or public randomness.

- Contains BMRS data © Elexon Limited copyright and database right 2026.
- Met Office rows in these vectors are synthetic, in the format documented by the Met Office Weather DataHub. Real sample data: https://datahub.metoffice.gov.uk/docs/o/category/observations/type/land-observations/sample-data
- drand beacons are public randomness published by the League of Entropy; no licence is claimed.

The Elexon readings for 2026-10-14 19:53:45–19:56:00 UTC are reproduced unaltered except for dropped fields; other frequency cases change them, as each file's description says. Provided as test data only; no endorsement by the Met Office or Elexon is implied.
