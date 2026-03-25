defmodule WallopCore.Resources.ApiKey do
  @moduledoc """
  API key for authenticating requests to the Wallop API.

  Keys are generated with a random secret, but only the bcrypt hash and an
  8-character prefix are persisted. The raw key is returned once via metadata
  after creation and never stored.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("api_keys")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:name])
      change({WallopCore.Resources.ApiKey.Changes.GenerateKey, []})
    end

    update :deactivate do
      accept([])

      change(set_attribute(:active, false))
      change(set_attribute(:deactivated_at, &DateTime.utc_now/0))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :key_hash, :string do
      allow_nil?(false)
      sensitive?(true)
      public?(false)
    end

    attribute :key_prefix, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :active, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :deactivated_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(false)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_prefix, [:key_prefix])
  end
end
