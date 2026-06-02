Vault Key Rotation
==================

The vault master key (`VAULT_KEY`) encrypts the three at-rest secret
columns: operator signing-key private bytes, infrastructure signing-key
private bytes, and API-key webhook secrets. Rotation is rare — yearly,
or immediately if compromised — but the procedure must be no-cutover:
no moment-T window where reads against the new key fail because old
rows still hold ciphertext under the previous one.

This runbook covers the **inspection** half of the procedure. The
mutating half (the migration task that re-encrypts rows to the new
tag, the end-to-end drill against staging) is Wave B, deferred until a
staging environment exists.

What you can do today: inspect the current state, understand what tag
every encrypted row is currently under, and confirm dual-key
configuration boots cleanly.

How rotation works at the cipher level
--------------------------------------

Cloak attaches a short `:tag` byte string as a prefix on every
ciphertext at encrypt time. On decrypt, Cloak looks at the tag prefix
and routes to whichever configured cipher carries the matching `:tag`.

This is why dual-key rotation can be no-cutover: configure two ciphers
simultaneously — `:default` (new key + new tag) for new writes,
`:retired` (old key + old tag) for legacy rows. Cloak picks the right
key per row without any application-level knowledge.

The tag constants pinned in `WallopCore.Vault.Config`:

- `@current_tag` — every new encrypted write attaches this.
- `@previous_tag` — rows under the prior master key carry this.

Bumping `@current_tag` is the load-bearing code change of a rotation.

Inspect the current state
-------------------------

`mix wallop.vault.verify_rotation` is read-only and safe to run at
any time on production. It reports, per encrypted column, how many
rows carry each known tag plus any unknown tags:

```
MIX_ENV=prod mix wallop.vault.verify_rotation
```

Sample output for steady-state production (no rotation in progress):

```
Vault rotation status
  current tag:  AES.GCM.V1
  previous tag: AES.GCM.V0

  table.column                                      current   previous   unknown   total
  --------------------------------------------------------------------------------------
  operator_signing_keys.private_key                 5         0          0         5
  infrastructure_signing_keys.private_key           2         0          0         2
  api_keys.webhook_secret                           7         0          0         7

All rows carry the current tag. Safe to drop VAULT_KEY_OLD.
```

Exit codes:

- `0` — every row carries the current tag. No rotation pending.
- `1` and `Rotation incomplete: N row(s)...` — at least one row still
  carries the previous tag. If a rotation is in progress, the
  migration step has not finished. If no rotation is in progress, the
  database holds ciphertext under a tag this build does not consider
  current — investigate before deploying.
- `1` and `N row(s) have an unrecognised tag` — the previous tag is
  set to something this build does not know. Possible causes: a
  rotation was started on a different code generation than is
  currently deployed (tag constants are mismatched between branches),
  or a row was inserted by foreign code.

What the boot logs tell you
---------------------------

`WallopCore.VaultHealthCheck` runs at every boot. Look for:

```
Vault round-trip OK label=:default cipher=Elixir.Cloak.Ciphers.AES.GCM tag=AES.GCM.V1
```

One such line per configured cipher. In single-key mode (production
today) there is exactly one. In dual-key mode (rotation overlap)
there are two, plus a WARN line that begins:

```
Vault is in DUAL-KEY rotation mode.
  current tag (writes): AES.GCM.V1
  retired tag (legacy): AES.GCM.V0
```

If you see that warning and you are not currently rotating, somebody
left `VAULT_KEY_OLD` set in the environment — drop it from secrets
and redeploy to close the rotation window.

If a round-trip line does NOT appear for `:default`, the app refused
to boot. The failure message says exactly which key-decode step
fell over.

The five-step rotation procedure (full sequence, for reference)
---------------------------------------------------------------

This is the procedure the rotation will follow once Wave B ships.
Step 3's migration task does not yet exist and steps 4–5 cannot run
in production today. Listed here so the structure is clear when
inspecting the codebase or the inspection task.

1. Bump `@current_tag` in `WallopCore.Vault.Config` (e.g. `V1` → `V2`)
   and `@previous_tag` to the old current value (e.g. → `V1`). PR
   the change. Do not deploy yet.

2. Mint a new master key. Set `VAULT_KEY=<new>` and
   `VAULT_KEY_OLD=<old>` simultaneously in the secrets store. Deploy.

   At this point both ciphers are configured. Reads of legacy rows
   still work via `:retired`. New writes use `:default`. The
   `VaultHealthCheck` boot log emits the dual-key warning.

3. **(Wave B)** Run `mix wallop.vault.migrate` against production.
   The task streams every encrypted row, decrypts it under whichever
   cipher matches, re-encrypts under `:default`, and writes the row
   back atomically. Idempotent: a row already under `:default` is a
   no-op.

4. Run `mix wallop.vault.verify_rotation`. Refuses to declare success
   while any row still carries the previous tag.

5. Drop `VAULT_KEY_OLD` from the secrets store. Redeploy. The vault
   is now back to single-cipher mode under the new key.

Wave B will add the migration task and a full drill procedure against
a staging environment. Until then: inspection only.
