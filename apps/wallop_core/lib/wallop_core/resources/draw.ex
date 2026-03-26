defmodule WallopCore.Resources.Draw do
  @moduledoc """
  A provably fair random draw.

  Draws follow a seven-state lifecycle:
  - **open** — draw created, entries may still be added before locking
  - **locked** — entries committed, waiting for seed or entropy declaration
  - **awaiting_entropy** — entropy sources declared, waiting for beacon data
  - **pending_entropy** — all entropy collected, ready for seed computation and execution
  - **completed** — seed applied, winners determined (terminal, immutable)
  - **failed** — entropy collection or execution failed (terminal, immutable)
  - **expired** — draw was never locked and has been abandoned (terminal, immutable)
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
      accept([:winner_count, :metadata, :callback_url])

      change(set_attribute(:api_key_id, actor(:id)))
      change(set_attribute(:status, :open))
      change({WallopCore.Resources.Draw.Changes.ValidateCallbackUrl, []})
      change({WallopCore.Resources.Draw.Changes.RecordStageTimestamp, key: "opened_at"})
    end

    create :create_manual do
      @doc "Internal only: creates a draw without entropy for testing and fallback use."
      accept([:entries, :winner_count, :metadata, :callback_url])

      validate attribute_does_not_equal(:entries, []) do
        message("must not be empty")
      end

      change(set_attribute(:api_key_id, actor(:id)))
      change(set_attribute(:status, :locked))
      change({WallopCore.Resources.Draw.Changes.ValidateEntries, []})
      change({WallopCore.Resources.Draw.Changes.ComputeEntryHash, []})
    end

    update :add_entries do
      require_atomic?(false)
      filter(expr(status == :open))

      argument :entries, {:array, :map} do
        allow_nil?(false)
      end

      change({WallopCore.Resources.Draw.Changes.ValidateEntries, []})
      change({WallopCore.Resources.Draw.Changes.AddEntries, []})
    end

    update :remove_entry do
      require_atomic?(false)
      filter(expr(status == :open))

      argument :entry_id, :string do
        allow_nil?(false)
      end

      change({WallopCore.Resources.Draw.Changes.RemoveEntry, []})
    end

    update :lock do
      require_atomic?(false)
      filter(expr(status == :open))

      change({WallopCore.Resources.Draw.Changes.LockDraw, []})
      change({WallopCore.Resources.Draw.Changes.DeclareEntropy, []})
      change({WallopCore.Resources.Draw.Changes.RecordStageTimestamp, key: "locked_at"})
      change({WallopCore.Resources.Draw.Changes.RecordStageTimestamp, key: "entropy_declared_at"})
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
      argument(:weather_observation_time, :utc_datetime_usec, allow_nil?: false)

      validate match(:drand_randomness, ~r/^[0-9a-f]{64}$/) do
        message("must be a 64-character lowercase hex string")
      end

      change({WallopCore.Resources.Draw.Changes.ExecuteWithEntropy, []})
    end

    update :expire do
      require_atomic?(false)
      filter(expr(status == :open))
      change(set_attribute(:status, :expired))
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

    policy action(:add_entries) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :open))
    end

    policy action(:remove_entry) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :open))
    end

    policy action(:lock) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :open))
    end

    policy action(:execute) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id) and status == :locked))
    end

    policy action(:read) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id)))
    end

    policy action(:expire) do
      authorize_if(always())
    end

    policy action([:transition_to_pending, :execute_with_entropy, :mark_failed]) do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :status, :atom do
      constraints(
        one_of: [
          :open,
          :locked,
          :awaiting_entropy,
          :pending_entropy,
          :completed,
          :failed,
          :expired
        ]
      )

      default(:open)
      allow_nil?(false)
      public?(true)
    end

    attribute :entries, {:array, :map} do
      allow_nil?(true)
      public?(true)
      default([])
    end

    attribute :entry_hash, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :entry_canonical, :string do
      allow_nil?(true)
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

    attribute :weather_observation_time, :utc_datetime_usec do
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

    attribute :stage_timestamps, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
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
