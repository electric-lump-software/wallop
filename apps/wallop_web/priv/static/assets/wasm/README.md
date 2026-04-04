# wallop_rs

Protocol functions and WASM verifier for the Wallop provably fair draw system.

Implements the cryptographic pipeline used to conduct and verify draws:
- canonical entry serialisation (JCS + SHA-256)
- seed derivation from drand randomness and an optional weather observation
- full end-to-end verification

WASM bindings expose every function to JavaScript via [wasm-bindgen](https://github.com/rustwasm/wasm-bindgen).

The draw algorithm itself lives in [`fair_pick_rs`](https://github.com/electric-lump-software/fair_pick_rs); this crate wraps it with the protocol layer.

---

## Functions

### `entry_hash(entries: &[Entry]) -> (String, String)`

Returns `(hex_hash, jcs)`.

Entries are sorted by `id` (lexicographic), then serialised as:

```json
{"entries":[{"id":"…","weight":N},…]}
```

The hash is the lowercase hex SHA-256 of those UTF-8 bytes.

---

### `compute_seed(entry_hash, drand_randomness, weather_value) -> ([u8; 32], String)`

Returns `(seed_bytes, jcs)`.

Canonical JSON (keys sorted alphabetically):

```json
{"drand_randomness":"…","entry_hash":"…","weather_value":"…"}
```

`seed_bytes` is the raw 32-byte SHA-256 of the JCS string.

---

### `compute_seed_drand_only(entry_hash, drand_randomness) -> ([u8; 32], String)`

Same as `compute_seed` but the `weather_value` key is omitted entirely, providing implicit domain separation — identical inputs will never produce the same seed as the weather variant.

---

### `verify(entries, drand_randomness, weather_value, count, expected_results) -> bool`

Runs the full pipeline — `entry_hash → compute_seed → draw → compare` — and returns `true` if the recomputed winners match `expected_results` exactly.

---

## Usage

### Rust

```rust
use wallop_rs::{Entry, entry_hash, compute_seed, verify};

let entries = vec![
    Entry { id: "ticket-47".into(), weight: 1 },
    Entry { id: "ticket-48".into(), weight: 1 },
    Entry { id: "ticket-49".into(), weight: 1 },
];

let drand = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
let weather = "1013";

let (ehash, _jcs) = entry_hash(&entries);
let (seed, _jcs) = compute_seed(&ehash, drand, weather);
// seed is [u8; 32], pass it to fair_pick_rs::draw or use verify()

let expected = fair_pick_rs::draw(&entries, &seed, 2).unwrap();
assert!(verify(&entries, drand, Some(weather), 2, &expected));
```

### WASM / JavaScript

```js
import init, {
  entry_hash_wasm,
  compute_seed_wasm,
  compute_seed_drand_only_wasm,
  verify_wasm,
} from "./pkg/wallop_rs.js";

await init();

const entries = [
  { id: "ticket-47", weight: 1 },
  { id: "ticket-48", weight: 1 },
  { id: "ticket-49", weight: 1 },
];

const { hash, jcs: entryJcs } = entry_hash_wasm(entries);

const { seed, jcs: seedJcs } = compute_seed_wasm(
  hash,
  "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
  "1013"
);

const ok = verify_wasm(
  entries,
  "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
  "1013",
  2,
  expectedWinners
);
```

---

## Building the WASM package

```bash
# Install wasm-pack (once)
cargo install wasm-pack

# Build for web — outputs to pkg/
wasm-pack build --target web
```

---

## Test vectors

All three vectors are enforced by the test suite (`cargo test`).

### P-1 — entry hash

| Field | Value |
|---|---|
| Input entries | `ticket-47` w=1, `ticket-48` w=1, `ticket-49` w=1 |
| JCS | `{"entries":[{"id":"ticket-47","weight":1},{"id":"ticket-48","weight":1},{"id":"ticket-49","weight":1}]}` |
| SHA-256 | `6056fbb6c98a0f04404adb013192d284bfec98975e2a7975395c3bcd4ad59577` |

### P-2 — seed derivation

| Field | Value |
|---|---|
| `entry_hash` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `drand_randomness` | `abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789` |
| `weather_value` | `1013` |
| JCS | `{"drand_randomness":"abcdef…","entry_hash":"e3b0c4…","weather_value":"1013"}` |
| SHA-256 | `4c1ae3e623dd22859d869f4d0cb34d3acaf4cf7907dbb472ea690e1400bfb0d0` |

### P-3 — end-to-end

| Field | Value |
|---|---|
| Entry hash | `6056fbb6c98a0f04404adb013192d284bfec98975e2a7975395c3bcd4ad59577` |
| Seed | `ced93f50d73a619701e9e865eb03fb4540a7232a588c707f85754aa41e3fb037` |
| Winner 1 | `ticket-48` |
| Winner 2 | `ticket-47` |

---

## JCS implementation

JSON Canonicalisation Scheme ([RFC 8785](https://www.rfc-editor.org/rfc/rfc8785)) is implemented manually for two fixed schemas rather than as a general-purpose serialiser. This keeps the implementation minimal and auditable:

- **Entry list schema** — `{"entries":[{"id":"…","weight":N},…]}`
- **Seed input schema** — `{"drand_randomness":"…","entry_hash":"…","weather_value":"…"}` (or without `weather_value`)

Keys are sorted alphabetically at build time; there is no runtime key sorting.

---

## Dependencies

| Crate | Purpose |
|---|---|
| [`fair_pick_rs`](https://github.com/electric-lump-software/fair_pick_rs) | Draw algorithm |
| [`sha2`](https://crates.io/crates/sha2) | SHA-256 |
| [`hex`](https://crates.io/crates/hex) | Hex encoding |
| [`wasm-bindgen`](https://crates.io/crates/wasm-bindgen) | WASM bindings |
| [`serde`](https://crates.io/crates/serde) + [`serde_json`](https://crates.io/crates/serde_json) | JSON (WASM boundary) |
| [`serde-wasm-bindgen`](https://crates.io/crates/serde-wasm-bindgen) | JS ↔ Rust value conversion |

---

## License

MIT — see [LICENSE](LICENSE).
