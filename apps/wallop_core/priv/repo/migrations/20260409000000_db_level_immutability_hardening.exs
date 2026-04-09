defmodule WallopCore.Repo.Migrations.DbLevelImmutabilityHardening do
  @moduledoc """
  Defence-in-depth fixes for three invariants whose only enforcement was
  the absence of an Ash action: signing-key append-only-ness, operator
  slug immutability, and bcrypt-format api key hashes.

  The corresponding Ash policies (added in the policy hardening sweep)
  closed the application-layer holes; this migration closes the
  direct-SQL-layer holes that the threat model matrix surfaced as gaps.

  All three changes are enforced by Postgres so even a future code path
  that bypasses Ash (raw Ecto, psql, a malicious migration) cannot
  silently break the invariants.

  Operators with `session_replication_role = 'replica'` access can still
  bypass the triggers for legitimate one-off interventions — that
  bypass is documented and auditable.
  """
  use Ecto.Migration

  def up do
    # ----- 1. operator_signing_keys append-only -----
    #
    # Reject all UPDATE and DELETE on operator_signing_keys. The table is
    # documented as append-only by the resource (rotation creates a new
    # row with a later valid_from), but the only thing enforcing it was
    # the absence of an Ash update action. Direct SQL could silently
    # mutate or remove a row, breaking the "old receipts verify forever"
    # guarantee for any signature that referenced the modified key.

    execute("""
    CREATE OR REPLACE FUNCTION prevent_signing_key_mutation()
    RETURNS TRIGGER AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'operator_signing_keys is append-only — UPDATE forbidden';
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'operator_signing_keys is append-only — DELETE forbidden';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER signing_key_immutability
    BEFORE UPDATE OR DELETE ON operator_signing_keys
    FOR EACH ROW EXECUTE FUNCTION prevent_signing_key_mutation();
    """)

    # ----- 2. operators.slug immutability -----
    #
    # Reject any UPDATE that changes the `slug` column. The slug is
    # embedded in every signed operator receipt as `operator_slug`, so
    # changing it after publication would silently break verification
    # for every existing receipt that references the operator. Other
    # columns on the row (e.g. `name`) remain mutable.

    execute("""
    CREATE OR REPLACE FUNCTION prevent_operator_slug_change()
    RETURNS TRIGGER AS $$
    BEGIN
      IF NEW.slug IS DISTINCT FROM OLD.slug THEN
        RAISE EXCEPTION 'operators.slug is immutable — UPDATE forbidden';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER operator_slug_immutability
    BEFORE UPDATE ON operators
    FOR EACH ROW EXECUTE FUNCTION prevent_operator_slug_change();
    """)

    # ----- 3. api_keys.key_hash CHECK constraint -----
    #
    # Constrain the bcrypt hash format. Without this, an attacker with
    # direct SQL access could replace a row's hash with garbage; bcrypt
    # verification of malformed input is library-dependent. The regex
    # matches the canonical bcrypt format: $2a$/$2b$/$2y$ prefix, two-
    # digit cost factor, then 22-char salt + 31-char hash = 53 chars.
    #
    # NOT VALID is intentional: it skips validation of pre-existing rows
    # so the migration can't break in environments that have unusual
    # historical data. New writes are always validated; old rows remain
    # tolerated until the next standalone validation step (which is a
    # follow-up if needed).

    execute("""
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_key_hash_format
    CHECK (key_hash ~ '^\\$2[aby]\\$[0-9]{2}\\$.{53}$') NOT VALID;
    """)
  end

  def down do
    execute("ALTER TABLE api_keys DROP CONSTRAINT IF EXISTS api_keys_key_hash_format;")

    execute("DROP TRIGGER IF EXISTS operator_slug_immutability ON operators;")
    execute("DROP FUNCTION IF EXISTS prevent_operator_slug_change();")

    execute("DROP TRIGGER IF EXISTS signing_key_immutability ON operator_signing_keys;")
    execute("DROP FUNCTION IF EXISTS prevent_signing_key_mutation();")
  end
end
