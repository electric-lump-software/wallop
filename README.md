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

## Using wallop_core as a dependency

If your app includes `wallop_core` as a dependency and shares the same database, you **must** configure Oban with a separate prefix to prevent your app competing with the wallop service for entropy and webhook jobs.

```elixir
# In your app's config.exs — use a different Oban prefix
config :wallop_core, Oban,
  repo: WallopCore.Repo,
  prefix: "oban_app",
  queues: [my_queue: 5],
  plugins: []
```

The wallop service uses the default `public` prefix. Your app uses `oban_app` (or any other name). Both share the database but never touch each other's jobs.

You will need to run `Oban.Migrations` for your prefix:

```elixir
defmodule MyApp.Repo.Migrations.AddObanAppJobs do
  use Ecto.Migration

  def up, do: Oban.Migration.up(prefix: "oban_app")
  def down, do: Oban.Migration.down(prefix: "oban_app")
end
```

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
