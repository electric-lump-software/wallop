# Entries Normalisation

Move draw entries from a JSONB array column on the `draws` table to a dedicated `entries` table. This removes the scaling bottleneck where every `add_entries` call reads, appends to, and rewrites the entire array, and where every draw read loads the full entry list regardless of need.

## Problem

The current `entries` column is `{:array, :map}` stored as JSONB. At scale:

- **Every `add_entries` rewrites the entire column** — appending to 50K entries means reading 50K, appending N, writing 50K+N back.
- **Duplicate checking** scans the full list in Elixir memory.
- **Every `Ash.get` of a draw loads all entries** — even when you just want the status.
- **`Proof.check_entry`** does a linear scan of the JSONB array to find one entry.

These are acceptable at hundreds of entries. At tens of thousands they're slow. At millions they're unworkable.

## Design

### New `entries` table

```sql
CREATE TABLE entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  draw_id UUID NOT NULL REFERENCES draws(id),
  entry_id TEXT NOT NULL,
  weight INTEGER NOT NULL DEFAULT 1,
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX entries_draw_id_entry_id ON entries(draw_id, entry_id);
CREATE INDEX entries_draw_id ON entries(draw_id);
```

- `entry_id` is the caller's opaque identifier (what's currently `entry["id"]`)
- `id` is an internal primary key (never exposed to callers)
- Unique index on `(draw_id, entry_id)` enforces no duplicates — replaces the Elixir `MapSet` scan
- Index on `draw_id` for efficient lookups

### Ash resource: `WallopCore.Resources.Entry`

New Ash resource backed by the `entries` table. Belongs to Draw. No direct API exposure — entries are managed through draw actions.

### API contract (Option C)

**Write path — unchanged for callers:**

`add_entries` still accepts `{"entries": [{"id": "...", "weight": N}, ...]}`. Internally it does a batch `INSERT INTO entries` instead of JSONB append. Duplicate detection is handled by the unique index (Postgres raises on conflict) rather than an Elixir `MapSet` scan.

`remove_entry` does `DELETE FROM entries WHERE draw_id = $1 AND entry_id = $2` instead of filtering and rewriting the JSONB array.

**Read path — changed:**

Draw responses no longer include the full entries array by default. Instead, the draw includes `entry_count` (integer).

Entries are read via a separate paginated endpoint:

```
GET /api/v1/draws/:id/entries?page[limit]=100&page[offset]=0
```

Returns entries sorted by `entry_id` (matching the hash computation order). This is important for verifiers who need to reconstruct the canonical entry list.

### Entry hash computation at lock time

No change to the protocol. `LockDraw` queries all entries from the table, converts to the atom-keyed format, and passes them to `Protocol.entry_hash/1` which sorts by `id` and computes `SHA-256(JCS(entries))`.

For the initial implementation, all entries are loaded into memory for hashing. At 1M entries (~50MB), this is manageable. Streaming hash computation can be added later (see PAM-435) without changing the canonical format.

### Concurrency: row-level locking

The critical race condition is between `add_entries` and `lock` — one transaction inserting entries while another locks the draw and computes the hash.

**Solution:** The `lock` action acquires a row-level lock on the draw (`SELECT ... FOR UPDATE`) before computing the entry hash. This serializes concurrent operations:

- If `add_entries` is mid-transaction, `lock` blocks until it commits, then hashes the complete set.
- If `lock` acquires first and transitions to `awaiting_entropy`, subsequent `add_entries` calls see the non-`open` status and are rejected.

Ash's atomic filter (`status == :open`) already provides this for the draw row. The entries table trigger adds the second layer.

### Immutability trigger on entries table

```sql
CREATE OR REPLACE FUNCTION prevent_entry_mutation()
RETURNS TRIGGER AS $$
DECLARE
  draw_status TEXT;
BEGIN
  -- Get the parent draw's status with a row lock
  IF TG_OP = 'INSERT' THEN
    SELECT status INTO draw_status FROM draws WHERE id = NEW.draw_id FOR UPDATE;
  ELSE
    SELECT status INTO draw_status FROM draws WHERE id = OLD.draw_id FOR UPDATE;
  END IF;

  -- Only allow modifications when the draw is open
  IF draw_status != 'open' THEN
    RAISE EXCEPTION 'Cannot modify entries on a % draw', draw_status;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER entries_immutability
  BEFORE INSERT OR UPDATE OR DELETE ON entries
  FOR EACH ROW EXECUTE FUNCTION prevent_entry_mutation();
```

This replaces the `entries IS DISTINCT FROM` check in the draws immutability trigger.

### ValidateEntries changes

Validation rules stay the same, but the implementation changes:

| Rule | Current | After normalisation |
|------|---------|-------------------|
| Max 10K entries | `length(entries) > 10_000` | `SELECT COUNT(*) FROM entries WHERE draw_id = $1` + batch size |
| Unique IDs | `MapSet` scan in Elixir | Unique index on `(draw_id, entry_id)` — Postgres raises on conflict |
| Structure (id + weight) | Elixir `Enum.all?` | Ash attribute validations on the Entry resource |
| Weight limits | Elixir scan | Ash attribute constraints |
| Total weight | `Enum.reduce` | `SELECT SUM(weight) FROM entries WHERE draw_id = $1` |

### Proof.check_entry

Changes from linear scan to indexed lookup:

```elixir
def check_entry(draw, entry_id) do
  case Repo.one(from e in Entry, where: e.draw_id == ^draw.id and e.entry_id == ^entry_id) do
    nil -> {:ok, %{found: false}}
    _entry ->
      # Check results (still on the draw record)
      winner = Enum.find(draw.results || [], fn r -> r["entry_id"] == entry_id end)
      if winner do
        {:ok, %{found: true, winner: true, position: winner["position"]}}
      else
        {:ok, %{found: true, winner: false}}
      end
  end
end
```

Constant time via the unique index, regardless of draw size.

### Proof.verify

Loads entries from the table instead of `draw.entries`:

```elixir
def verify(draw) do
  entries = Repo.all(from e in Entry, where: e.draw_id == ^draw.id)
  atom_entries = Enum.map(entries, fn e -> %{id: e.entry_id, weight: e.weight} end)
  # ... rest unchanged
end
```

### ExecuteDraw / ExecuteWithEntropy / ExecuteSandbox

All three execute paths currently read `draw.entries`. After normalisation, they load entries from the table. The entry hash integrity check remains — recompute from the table data and verify against the stored `entry_hash`.

### Draw resource changes

- Remove `entries` attribute (the JSONB column)
- Add `entry_count` attribute (denormalized integer, updated atomically on add/remove)
- Add `has_many :entries, WallopCore.Resources.Entry` relationship
- Update `add_entries` action to create Entry records
- Update `remove_entry` action to delete Entry records
- Update `lock` action to load entries from the relationship

### Migration strategy

1. Add the `entries` table and Entry resource
2. Migrate existing JSONB data: for each draw, insert rows into `entries` from the JSONB array
3. Verify hash equality: for every draw, recompute `entry_hash` from the table data and assert it matches the stored hash
4. Update all change modules and Proof to read from the table
5. Update the draws immutability trigger to remove `entries IS DISTINCT FROM` check
6. Drop the `entries` JSONB column from draws
7. Regenerate OpenAPI spec

Steps 2-3 run as a data migration with verification. Steps 4-6 are code changes that deploy together.

### What does NOT change

- The entry hash algorithm (`Protocol.entry_hash/1`)
- The FairPick algorithm
- The commit-reveal protocol
- The seed computation
- The proof page UI (except entries are loaded separately)
- Test vectors

## Postgres extensions

No extensions needed for the core normalisation. The unique index on `(draw_id, entry_id)` handles duplicate detection and fast lookups natively.

If we later need full-text search on entry IDs or more exotic indexing, `pg_trgm` could be useful, but that's not in scope here.

## Scope

**In scope:**
- New `entries` table + Entry resource
- Migrate `AddEntries`, `RemoveEntry`, `LockDraw`, all execute changes, Proof module
- Paginated entries endpoint
- Data migration with hash verification
- Immutability trigger on entries table
- Update draws trigger to remove entries column reference
- `entry_count` on draw
- Tests for all of the above

**Out of scope (see PAM-435):**
- Bulk entry download endpoint for verification
- Streaming hash computation for very large draws
- Entry count denormalisation trade-offs

## Risk

The main risk is the data migration — existing draws must produce identical hashes after migration. This is testable and verifiable. The protocol itself is unchanged; this is a storage refactor.
