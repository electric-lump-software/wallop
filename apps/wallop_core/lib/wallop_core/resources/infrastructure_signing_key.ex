defmodule WallopCore.Resources.InfrastructureSigningKey do
  @moduledoc """
  A wallop-wide Ed25519 signing keypair for execution receipts.

  Phase-separated from operator signing keys by design: operators sign
  commitments (lock receipts), wallop infrastructure signs execution
  attestations (execution receipts). The operator was not the witness to
  execution — they weren't running the drand client or the weather fetch.
  Same-key would force the operator to sign a statement they're not the
  actual witness to.

  Append-only with `valid_from` ordering, same pattern as
  `OperatorSigningKey`. The "current" key is the row with the largest
  `valid_from <= now`. Old keys remain forever so historical execution
  receipts continue to verify.

  One wallop-wide key — not per-operator, not per-environment. Manual
  annual rotation via `mix wallop.rotate_infrastructure_key`. Published
  at `GET /infrastructure/key`.
  """

  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("infrastructure_signing_keys")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:key_id, :public_key, :private_key, :valid_from])
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
    identity(:unique_key_id, [:key_id])
  end
end
