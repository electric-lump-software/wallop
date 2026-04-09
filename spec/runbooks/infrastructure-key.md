# Infrastructure Signing Key

The infrastructure key signs execution receipts. It is separate from
operator signing keys (which sign lock receipts). One key for all of
wallop — not per-operator.

## When to run this

Bootstrap must happen after the first deploy that includes the
execution receipt migration (`20260409100000_add_execution_receipts`).
The migration creates the tables; it does not insert a key (Vault
must be running, which a migration can't assume).

If you forget, draws will fail with a clear error telling you to run
the bootstrap task. The draw rolls back — no silent failures, no
half-signed state.

## First-time setup

Run once, after that first deploy:

```
MIX_ENV=prod mix wallop.bootstrap_infrastructure_key
```

It prints the `key_id` and hex public key. The key is Vault-encrypted
at rest.

## Annual rotation

Once a year, or immediately if compromised:

```
MIX_ENV=prod mix wallop.rotate_infrastructure_key
```

That's it. The old key stays forever (historical receipts still verify).
New receipts use the new key immediately. No restart needed.

## Verifying the current key

```
curl https://your-domain/infrastructure/key \
  -o /dev/null -w '%{http_code}' -s -D -
```

Look for `x-wallop-key-id` in the response headers.

## If the key is compromised

1. Rotate immediately: `MIX_ENV=prod mix wallop.rotate_infrastructure_key`
2. Note the old `key_id` and the time window of suspected compromise
3. Flag affected receipts in the database:
   ```sql
   UPDATE execution_receipts
   SET potentially_compromised_at = NOW()
   WHERE signing_key_id = '<old-key-id>'
     AND inserted_at BETWEEN '<start>' AND '<end>';
   ```
4. Publish an incident notice on the transparency page

Lock receipts (operator-signed) are completely unaffected by an infra
key compromise. That's the whole point of phase-separated keys.

## What NOT to do

- Do not delete old keys. Ever. Historical receipts need them.
- Do not re-sign old execution receipts. That violates append-only
  semantics and the `unique_draw` constraint will reject it anyway.
- Do not share the private key between environments. Each deployment
  bootstraps its own.
