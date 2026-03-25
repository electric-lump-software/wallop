# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Draw resource with locked/completed state machine and ownership policies
- Execute action: caller-provided seed runs FairPick algorithm, stores results
- ApiKey resource with bcrypt hashing and prefix-based lookup
- Mix tasks: `wallop.gen.api_key`, `wallop.list.api_keys`, `wallop.deactivate.api_key`
- JSON:API endpoints: POST /draws, PATCH /draws/:id/execute, GET /draws/:id, GET /draws
- Bearer token authentication with timing-safe bcrypt verification
- ETS-based rate limiting on auth failures (10/min per IP)
- PostgreSQL immutability trigger (completed draws cannot be modified, locked draw committed fields protected)
- Ash policies enforcing draw ownership and status constraints
- Protocol integration test against frozen spec vector P-3

## [0.1.0] - 2026-03-24

### Added

- Elixir umbrella project structure (`wallop_core`, `wallop_web`)
- `WallopCore.Protocol.entry_hash/1` — entry list hashing per protocol spec §2.1
- `WallopCore.Protocol.compute_seed/3` — seed computation from entropy sources per protocol spec §2.3
- Protocol test vectors P-1, P-2, P-3 (frozen, canonical)
- GitHub Actions CI (format, credo, tests)
