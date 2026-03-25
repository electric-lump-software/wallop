defmodule WallopCore.Resources.Draw do
  @moduledoc """
  A provably fair random draw.

  Draws follow a five-state lifecycle:
  - **locked** — entries committed, waiting for seed or entropy declaration
  - **awaiting_entropy** — entropy sources declared, waiting for beacon data
  - **pending_entropy** — all entropy collected, ready for seed computation and execution
  - **completed** — seed applied, winners determined (terminal, immutable)
  - **failed** — entropy collection or execution failed (terminal, immutable)
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
      accept([:entries, :winner_count, :metadata, :callback_url])

      validate attribute_does_not_equal(:entries, []) do
        message("must not be empty")
      end

      change(set_attribute(:api_key_id, actor(:id)))
      change({WallopCore.Resources.Draw.Changes.ValidateEntries, []})
      change({WallopCore.Resources.Draw.Changes.ComputeEntryHash, []})
      change({WallopCore.Resources.Draw.Changes.DeclareEntropy, []})
    end

    create :create_manual do
      @doc "Internal only: creates a draw without entropy for testing and fallback use."
      accept([:entries, :winner_count, :metadata, :callback_url])

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

      validate({WallopCore.Resources.Draw.Validations.NoEntropyDeclared, []})

      # Atomic filter: ensures the row is still :locked at UPDATE time,
      # preventing race conditions with concurrent execute requests.
      filter(expr(status == :locked))

      change({WallopCore.Resources.Draw.Changes.ExecuteDraw, []})
    end

    update :transition_to_pending do
      require_atomic?(false)
      filter(expr(status == :awaiting_entropy))
      change(set_attribute(:status, :pending_entropy))
    end

    update :execute_with_entropy do
      require_atomic?(false)
      filter(expr(status == :pending_entropy))

      argument(:drand_randomness, :string, allow_nil?: false)
      argument(:drand_signature, :string, allow_nil?: false)
      argument(:drand_response, :string, allow_nil?: false)
      argument(:weather_value, :string, allow_nil?: false)
      argument(:weather_raw, :string, allow_nil?: false)

      validate match(:drand_randomness, ~r/^[0-9a-f]{64}$/) do
        message("must be a 64-character lowercase hex string")
      end

      change({WallopCore.Resources.Draw.Changes.ExecuteWithEntropy, []})
    end

    update :mark_failed do
      require_atomic?(false)
      filter(expr(status in [:pending_entropy, :awaiting_entropy]))

      argument(:failure_reason, :string, allow_nil?: false)

      change(set_attribute(:status, :failed))
      change(set_attribute(:failed_at, &DateTime.utc_now/0))

      change(fn changeset, _context ->
        reason = Ash.Changeset.get_argument(changeset, :failure_reason)
        Ash.Changeset.force_change_attribute(changeset, :failure_reason, reason)
      end)
    end
  end

  policies do
    policy action(:create) do
      authorize_if(actor_present())
    end

    # INTERNAL ONLY: :create_manual bypasses entropy declaration.
    # Must NEVER be exposed via JSON:API routes. Used only by tests
    # and internal fallback integrations (produces unverified draws).
    policy action(:create_manual) do
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

    policy action([:transition_to_pending, :execute_with_entropy, :mark_failed]) do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :status, :atom do
      constraints(one_of: [:locked, :awaiting_entropy, :pending_entropy, :completed, :failed])
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

    attribute :drand_chain, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :drand_round, :integer do
      allow_nil?(true)
      public?(true)
    end

    attribute :drand_randomness, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :drand_signature, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :drand_response, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :weather_station, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :weather_time, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :weather_value, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :weather_raw, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :callback_url, :string do
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

    attribute :failed_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :failure_reason, :string do
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
