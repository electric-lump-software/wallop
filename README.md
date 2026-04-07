# Wallop

Provably fair random draw service. Commit-reveal protocol with public entropy.

## What is this?

Wallop runs verifiably fair random draws where nobody controls the outcome — not the organiser, not the platform, not the service itself.

Entries are locked before the draw. The seed is computed from public, unpredictable entropy sources. The algorithm is open source and deterministic. Anyone can re-run it and verify the result.

## How it works

1. **Lock entries** — caller submits entry list, Wallop computes and publishes the entry hash
2. **Commit** — Wallop declares which future entropy sources will be used (drand beacon round + weather observation time)
3. **Fetch entropy** — after the declared time, Wallop fetches randomness from [drand](https://drand.love) and a Met Office weather reading
4. **Compute seed & run** — entropy sources are combined via JCS + SHA256 to produce a seed, which is fed into the deterministic [fair_pick](https://github.com/electric-lump-software/fair_pick) algorithm
5. **Permanent proof** — the full proof record (entries, entropy, seed, results) is stored permanently with a public verification page

## Cross-draw verifiability (operator registry)

Single-draw verifiability — the commit-reveal protocol above — proves any *one* draw was fair. It does not prove that the operator running the draw didn't quietly run nine others and only publish the result they liked. That gap is closed by the **operator registry**:

- Every API key may belong to an `Operator`. Operators are public identities with a stable slug.
- Every draw an operator locks gets a **gap-free per-operator sequence number**. Discarded, expired, and failed draws still occupy their slot — gaps are detectable.
- At lock time, wallop_core signs an Ed25519 **commitment receipt** over the canonical JSON `{operator, sequence, draw_id, commitment_hash, entry_hash, locked_at, signing_key_id, schema_version}`. The receipt is inserted in the same transaction as the lock, so a draw cannot be locked without its receipt being committed atomically.
- The operator's public registry lives at `/operator/:slug` and lists every draw they have ever locked, in sequence order, with status badges. Signed receipts are served as JSON at `/operator/:slug/receipts` and individually at `/operator/:slug/receipts/:n`. The current Ed25519 public key is at `/operator/:slug/key`.
- A **transparency log** at `/transparency` publishes a daily Merkle root over all receipts, pinned to a drand round number. Mirroring the receipt log over time and recomputing the root lets a third party detect any retroactive tampering with operator receipts.

This defends against **post-hoc draw shopping**: lock a draw, see the result, dislike it, discard it, lock another with the same entries on a fresh round, repeat. After this change every locked draw is permanently visible in the operator's registry whether it eventually completed or not, and the signed receipt commits the operator to *that* entry set resolving to *some* outcome at *that* sequence slot. Anyone can verify the receipts independently using the operator's public key.

It does **not** defend against an operator locking parallel draws with *different* entry sets. Operators must follow "one contest = one locked draw."

Signing keys can be rotated by inserting a new `OperatorSigningKey` row with a later `valid_from` timestamp; old keys are never deleted, so previously published receipts remain verifiable forever.

## Architecture

| Layer | Package | Purpose |
|-------|---------|---------|
| **Algorithm** | [`fair_pick`](https://github.com/electric-lump-software/fair_pick) (separate repo) | Deterministic `(entries, seed) → winners`. Pure functions, zero side effects. |
| **Protocol** | `wallop_core` (this repo) | Commit-reveal protocol, entropy fetching, seed computation |
| **Web** | `wallop_web` (this repo) | Proof pages, API endpoints, live draws |

## Using wallop_core as a dependency

If your app includes `wallop_core` as a dependency and shares the same database, you **must** configure Oban with a separate prefix. Each service processes its own draws independently — the code is identical (wallop_core), the algorithm is deterministic, and the proof is independently verifiable regardless of which service executed the draw.

```elixir
# In your app's config.exs — use a different Oban prefix
config :wallop_core, Oban,
  repo: WallopCore.Repo,
  prefix: "oban_app",
  queues: [entropy: 10, webhooks: 5, default: 5],
  plugins: []
```

The wallop service uses the default `public` prefix. Your app uses `oban_app` (or any other name). Both share the database but process their own jobs independently.

You will need to run `Oban.Migrations` for your prefix:

```elixir
defmodule MyApp.Repo.Migrations.AddObanAppJobs do
  use Ecto.Migration

  def up, do: Oban.Migration.up(prefix: "oban_app")
  def down, do: Oban.Migration.down(prefix: "oban_app")
end
```

Your app also needs `MET_OFFICE_API_KEY` and `HONEYCOMB_API_KEY` environment variables set, since the EntropyWorker and OTel exporter run in your process. Set a distinct OTel service name so traces are separated in Honeycomb:

```elixir
# In your app's runtime.exs
config :opentelemetry,
  resource: [service: [name: "wallop-app"]]
```

PubSub works across services automatically via Redis — draw updates broadcast from either service are received by both.

## Entry IDs and GDPR

Wallop never stores personally identifiable information. Entry IDs must be **opaque identifiers** — UUIDs, numeric IDs, or similar. Email addresses, phone numbers, and names are rejected by the API.

The recommended integration pattern:

1. Your app holds the mapping from person to opaque ID (e.g. `user_id → "a1b2c3"`)
2. Your app sends only the opaque ID to Wallop as the entry ID
3. Wallop hashes the entry list into a permanent, immutable proof record
4. On a GDPR deletion request, your app deletes the person's record and the ID mapping — the Wallop proof record remains intact because it contains no PII

Entry IDs are restricted to `^[a-zA-Z0-9_\-:.=]+$` (alphanumeric, hyphens, underscores, dots, colons, equals). This blocks common PII patterns at the API level while allowing UUIDs, numeric IDs, and base64-encoded values.

## Tech stack

- **Language:** Elixir
- **Framework:** Phoenix + Ash Framework
- **Database:** PostgreSQL
- **API format:** JSON:API

## Development

This repo depends on the [`fair_pick`](https://github.com/electric-lump-software/fair_pick) package as a sibling directory. Clone both repos side by side:

```bash
git clone git@github.com:electric-lump-software/wallop.git
git clone git@github.com:electric-lump-software/fair_pick.git
```

Then:

```bash
cd wallop
mix deps.get
mix ash.setup       # creates database and runs migrations
mix test
mix format
mix credo --strict
```

## Status

Active development. The algorithm, protocol layer, API, entropy layer (drand + Met Office weather), and public proof pages are all implemented.

## License

MIT — see [LICENSE](LICENSE).
