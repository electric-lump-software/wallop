defmodule WallopCore.Resources.SigningKeyRevocation do
  @moduledoc """
  A record that a signing key has been withdrawn. A revoked key is never
  served, never used to sign, and never resolved for verification: every
  read of `InfrastructureSigningKey` and `OperatorSigningKey` excludes it.

  Revoking keeps the key row (the key tables are append-only) and adds a row
  here instead, so the keyring stays intact as evidence of what existed.
  This table is append-only too: a revocation cannot be undone by UPDATE,
  DELETE or TRUNCATE.

  Write through `WallopCore.KeyRotation.revoke_superseded_keys/0`.
  """

  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("signing_key_revocations")
    repo(WallopCore.Repo)

    references do
      reference(:operator, on_delete: :restrict)
    end

    check_constraints do
      check_constraint(:operator_id, "signing_key_revocations_operator_matches_class",
        check:
          "(key_class = 'operator' AND operator_id IS NOT NULL) OR (key_class = 'infrastructure' AND operator_id IS NULL)",
        message: "must be set for operator keys and empty for infrastructure keys"
      )
    end

    custom_statements do
      statement :signing_key_revocations_append_only do
        up("""
        DO $do$
        BEGIN
          CREATE OR REPLACE FUNCTION prevent_signing_key_revocation_mutation() RETURNS trigger AS $fn$
          BEGIN
            RAISE EXCEPTION 'signing_key_revocations is append-only — % forbidden', TG_OP;
          END;
          $fn$ LANGUAGE plpgsql;
          DROP TRIGGER IF EXISTS signing_key_revocation_immutability ON signing_key_revocations;
          CREATE TRIGGER signing_key_revocation_immutability
            BEFORE UPDATE OR DELETE ON signing_key_revocations
            FOR EACH ROW EXECUTE FUNCTION prevent_signing_key_revocation_mutation();
          DROP TRIGGER IF EXISTS signing_key_revocations_no_truncate ON signing_key_revocations;
          CREATE TRIGGER signing_key_revocations_no_truncate
            BEFORE TRUNCATE ON signing_key_revocations
            EXECUTE FUNCTION prevent_signing_key_revocation_mutation();
        END
        $do$
        """)

        down("""
        DO $do$
        BEGIN
          DROP TRIGGER IF EXISTS signing_key_revocations_no_truncate ON signing_key_revocations;
          DROP TRIGGER IF EXISTS signing_key_revocation_immutability ON signing_key_revocations;
          DROP FUNCTION IF EXISTS prevent_signing_key_revocation_mutation();
        END
        $do$
        """)
      end
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:key_class, :key_id, :operator_id, :reason])
    end
  end

  policies do
    policy action(:read) do
      authorize_if(always())
    end

    policy action(:create) do
      forbid_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :key_class, :atom do
      constraints(one_of: [:infrastructure, :operator])
      allow_nil?(false)
      public?(true)
    end

    attribute :key_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :reason, :string do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:revoked_at)
  end

  relationships do
    belongs_to :operator, WallopCore.Resources.Operator do
      allow_nil?(true)
      public?(false)
      attribute_writable?(true)
    end
  end

  identities do
    identity(:unique_revocation, [:key_class, :operator_id, :key_id], nils_distinct?: false)
  end
end
