defmodule WallopCore.Resources.OperatorSigningKey do
  @moduledoc """
  An Ed25519 signing keypair belonging to an operator.

  Append-only: rotation creates a new row, never updates an existing one. The
  *current* key is the row with the largest `valid_from <= now`. Each row has
  a short `key_id` (first 8 hex chars of `sha256(public_key)`) that gets
  embedded in every signed receipt so verifiers can pick the right pubkey
  even after rotation.

  The private key is stored as Cloak-encrypted bytes using `WallopCore.Vault`.
  """

  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("operator_signing_keys")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:operator_id, :key_id, :public_key, :private_key, :valid_from])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :operator_id, :uuid do
      allow_nil?(false)
      public?(false)
    end

    attribute :key_id, :string do
      description("Short fingerprint: first 8 hex chars of sha256(public_key).")
      allow_nil?(false)
      public?(true)
    end

    attribute :public_key, :binary do
      description("Raw 32-byte Ed25519 public key.")
      allow_nil?(false)
      public?(true)
    end

    attribute :private_key, :binary do
      description("Cloak-encrypted Ed25519 private key. Never exposed via API.")
      allow_nil?(false)
      public?(false)
      sensitive?(true)
    end

    attribute :valid_from, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_key_id, [:operator_id, :key_id])
  end

  relationships do
    belongs_to :operator, WallopCore.Resources.Operator do
      allow_nil?(false)
      public?(false)
      attribute_writable?(true)
    end
  end
end
