defmodule WallopCore.Resources.Draw do
  @moduledoc """
  A provably fair random draw.

  Draws follow a two-phase lifecycle: **locked** (entries committed, waiting for
  seed) and **completed** (seed applied, winners determined). Once completed, a
  draw record is immutable.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource]

  json_api do
    type("draw")
  end

  postgres do
    table("draws")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:entries, :winner_count, :metadata])

      validate attribute_does_not_equal(:entries, []) do
        message("must not be empty")
      end

      change(set_attribute(:api_key_id, actor(:id)))
      change({WallopCore.Resources.Draw.Changes.ValidateEntries, []})
      change({WallopCore.Resources.Draw.Changes.ComputeEntryHash, []})
    end

    update :execute do
      require_atomic?(false)

      argument :seed, :string do
        allow_nil?(false)
      end

      validate match(:seed, ~r/^[0-9a-fA-F]{64}$/) do
        message("must be a 64-character hex string")
      end

      # Atomic filter: ensures the row is still :locked at UPDATE time,
      # preventing race conditions with concurrent execute requests.
      filter(expr(status == :locked))

      change({WallopCore.Resources.Draw.Changes.ExecuteDraw, []})
    end
  end

  policies do
    policy action(:create) do
      authorize_if(actor_present())
    end

    policy action(:execute) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :locked))
    end

    policy action(:read) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :status, :atom do
      constraints(one_of: [:locked, :completed])
      default(:locked)
      allow_nil?(false)
      public?(true)
    end

    attribute :entries, {:array, :map} do
      allow_nil?(false)
      public?(true)
    end

    attribute :entry_hash, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :entry_canonical, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :winner_count, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1, max: 10_000)
    end

    attribute :seed, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :seed_source, :atom do
      constraints(one_of: [:caller, :entropy])
      allow_nil?(true)
      public?(true)
    end

    attribute :seed_json, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :results, {:array, :map} do
      allow_nil?(true)
      public?(true)
    end

    attribute :metadata, :map do
      allow_nil?(true)
      public?(true)
    end

    attribute :executed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :api_key, WallopCore.Resources.ApiKey do
      allow_nil?(false)
      public?(false)
    end
  end
end
