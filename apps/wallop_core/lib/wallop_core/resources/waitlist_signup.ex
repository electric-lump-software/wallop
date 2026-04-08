defmodule WallopCore.Resources.WaitlistSignup do
  @moduledoc "Stores email addresses for the pre-launch waitlist."
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("waitlist_signups")
    repo(WallopCore.Repo)
  end

  actions do
    create :create do
      primary?(true)
      accept([:email])
    end
  end

  policies do
    # Public signup form — anonymous create is intentional and explicit.
    policy action(:create) do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :email, :ci_string do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_email, [:email])
  end
end
