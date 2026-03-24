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

## Architecture

| Layer | Package | Purpose |
|-------|---------|---------|
| **Algorithm** | [`fair_pick`](https://github.com/electric-lump-software/fair_pick) (separate repo) | Deterministic `(entries, seed) → winners`. Pure functions, zero side effects. |
| **Protocol** | `wallop_core` (this repo) | Commit-reveal protocol, entropy fetching, seed computation |
| **Web** | `wallop_web` (this repo) | Proof pages, API endpoints, live draws |

## Tech stack

- **Language:** Elixir
- **Framework:** Phoenix (coming soon)
- **Database:** PostgreSQL (coming soon)

## Development

```bash
mix deps.get
mix test
mix format
mix credo --strict
```

## Status

Early development. The algorithm ([fair_pick](https://github.com/electric-lump-software/fair_pick)) and protocol layer are complete. API and web layer are next.

## License

MIT — see [LICENSE](LICENSE).
