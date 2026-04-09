## Protocol-critical files changed

This PR touches files that affect wallop's cryptographic verification story. Please confirm:

- [ ] wallop_core version bumped in `mix.exs`?
- [ ] CHANGELOG entry added?
- [ ] Frozen test vectors updated deliberately (not accidentally)?
- [ ] `spec/protocol.md` updated if the payload format changed?
- [ ] Does this change break historical proof verifiability? If yes, schema version bump required.
- [ ] Have you run the full frozen vector suite locally? (`mix test apps/wallop_core/test/wallop_core/frozen_vectors_test.exs`)
