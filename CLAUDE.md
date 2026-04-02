# CLAUDE.md — Wallop

Provably fair random draw service. Used by PAM (PTA management app) and available as a standalone API.

## What this project is

A three-layer system for running verifiably fair random draws:
1. **`fair_pick` hex package** (separate repo) — deterministic `(entries, seed) → winners` algorithm. Open source.
2. **API** (this repo, `wallop_core`) — commit-reveal protocol with public entropy. Open source.
3. **Web app** (this repo, `wallop_web`) — permanent proof records and public verification pages. Open source.

The trust model: nobody controls the outcome. Entries are locked before the draw. The seed is computed from public, unpredictable entropy sources. The algorithm is open source and deterministic. Anyone can re-run it.

## Tech stack

- **Language:** Elixir
- **Framework:** Phoenix
- **Database:** PostgreSQL
- **Hex package:** Pure Elixir, zero dependencies (except `:crypto` from OTP)

## Architecture

Read `docs/decisions/0001-picker-architecture.md` before doing anything. It covers:
- The commit-reveal protocol
- API design (endpoints, request/response formats)
- Data model
- Integration with PAM
- Security considerations
- MVP scope

## Domain boundaries (CRITICAL)

This repo is **open source**. Consuming apps (e.g. wallop-app) are **closed source**. The boundary must be airtight:

- **wallop_core must NEVER reference WallopWeb, WallopApp, or any closed-source module.** Core is a standalone dependency.
- **wallop_web may reference wallop_core** (it depends on it), but never closed-source app modules.
- **No PAM/wallop-app business logic in this repo.** This repo is the protocol layer and proof pages only.
- **No closed-source config assumptions.** If wallop_core needs config, it must work with sensible defaults or raise on missing values. Don't assume wallop-app's config structure.
- **Oban jobs belong to the service that enqueued them.** Consuming apps use a separate Oban prefix. Never assume which service will process a job.
- **All draw mutations must be auditable.** Any code that touches draw state (entropy, execution, results) must live in wallop_core, not in a consuming app.

The boundary test at `test/wallop_core/boundary_test.exs` enforces this in CI.

## Key design principles

- **Deterministic algorithm:** Same inputs MUST always produce the same outputs. This is the foundation of verifiability.
- **No side effects in the hex package:** Pure functions only. No network, no randomness, no state.
- **Immutable records:** Once a draw is executed, the record cannot be modified. No UPDATE or DELETE on completed draws.
- **Opaque entry IDs:** The picker never knows who entries belong to. It receives IDs and weights, not PII.
- **Test vectors are the spec:** Published test vectors define correctness. Any reimplementation must produce identical output.

## Commands

```bash
# Setup
mix setup

# Development
mix phx.server

# Testing
mix test
mix test path/to/test.exs

# Quality
mix format
mix compile --warnings-as-errors
mix credo --strict
```

## MVP scope

**In scope:**
- `fair_pick` hex package with deterministic algorithm + test vectors
- API: create draw (lock entries), execute draw, get results
- Commit-reveal with drand + weather entropy
- Public verification page per draw
- API key authentication
- PostgreSQL with immutability constraints

**Not MVP:**
- User accounts / self-service signup
- Billing
- Standalone draw creation UI
- Marketing site
- Webhook notifications

## Relationship to PAM

PAM is the primary consumer. PAM's `Lottery` resource calls the picker API when a committee runs a raffle draw. PAM stores the winner list and a proof URL. All cryptographic proof (seed, entropy, commitment) lives here in the picker, not in PAM.

PAM also bundles the `fair_pick` hex package as an inline fallback. Draws via fallback are marked "unverified" (no proof URL).

## PR checklist

Every PR must include:
- `mix format` — no formatting violations
- `mix credo --strict` — no credo issues
- `mix test` — all tests pass
- **CHANGELOG.md** — update with a summary of changes under an `[Unreleased]` section
- **README.md** — update if the PR changes public API, adds features, or alters usage
- **Version bump** — bump version in `mix.exs` when releasing (follow semver)

The same checklist applies to PRs on the `fair_pick` repo (`electric-lump-software/fair_pick`).
