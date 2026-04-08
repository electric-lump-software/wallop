defmodule WallopCore.Resources.SandboxDraw do
  @moduledoc """
  A dev/test "try it out" draw executed against a publicly-known seed.

  Sandbox draws are structurally separate from real draws (see PAM-670):

  - Own table (`sandbox_draws`), own primary key, no foreign key to `draws`
  - No `operator_sequence` — sandbox draws are NOT part of the operator's
    append-only fairness record
  - No `OperatorReceipt` — sandbox draws are NOT signed and are NOT included
    in the transparency log
  - No lifecycle: create-and-execute in a single transaction. There is no
    lock step, no awaiting_entropy, no state an attacker could divert
    between phases.
  - No `entry_hash` commitment — the entries live inline as embedded JSON
    and are never read by anything other than the row's own create action

  This separation exists because sharing a resource / table / sequence with
  real draws makes "every row on the public registry is a committed fair
  draw" an aspirational invariant enforced in code, not a structural one
  enforced by the schema. Postgres itself should refuse to confuse a
  sandbox run with a committed fair outcome.

  The sandbox seed is published and deterministic. Same inputs produce the
  same winners every time. Use this for UI rehearsal, never for anything
  that matters.
  """
  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias WallopCore.Resources.SandboxDraw

  @typedoc "Published sandbox seed: `SHA-256(\"wallop-sandbox\")` as lowercase hex."
  @type seed_hex :: String.t()

  # The sandbox seed is computed at compile time from the literal input
  # string so anyone reading the source can verify exactly what goes into
  # SHA-256. Don't replace this with a pre-hashed hex blob — visibility of
  # the input matters.
  @seed_input "wallop-sandbox"
  @seed_hex @seed_input |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  @doc "Returns the published sandbox seed as lowercase hex."
  @spec seed_hex() :: seed_hex()
  def seed_hex, do: @seed_hex

  @doc "Returns the literal input string fed to SHA-256 to produce the sandbox seed."
  @spec seed_input() :: String.t()
  def seed_input, do: @seed_input

  postgres do
    table("sandbox_draws")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      description("Create-and-execute a sandbox draw in a single transaction.")
      accept([:name, :winner_count])

      argument :entries, {:array, :map} do
        allow_nil?(false)
        description("Entry list to run through the sandbox seed.")
      end

      change({SandboxDraw.Changes.SetActorFields, []})
      change({SandboxDraw.Changes.ValidateEntries, []})
      change({SandboxDraw.Changes.ExecuteWithSandboxSeed, []})
      change({SandboxDraw.Changes.EmitCreateTelemetry, []})
    end
  end

  policies do
    policy action(:create) do
      authorize_if(actor_present())
    end

    policy action(:read) do
      forbid_unless(actor_present())
      authorize_if(expr(api_key_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(true)
      public?(true)
      constraints(max_length: 255)
    end

    attribute :winner_count, :integer do
      allow_nil?(false)
      public?(true)
      constraints(min: 1, max: 10_000)
    end

    attribute :entries, {:array, :map} do
      description("Submitted entries (embedded JSON).")
      allow_nil?(false)
      default([])
      public?(true)
    end

    attribute :seed, :string do
      description("Constant published sandbox seed (see `SandboxDraw.seed_hex/0`).")
      allow_nil?(false)
      public?(true)
    end

    attribute :results, {:array, :map} do
      description("Winners selected by `fair_pick` using the sandbox seed.")
      allow_nil?(false)
      default([])
      public?(true)
    end

    attribute :executed_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :api_key, WallopCore.Resources.ApiKey do
      allow_nil?(false)
      attribute_writable?(true)
    end

    belongs_to :operator, WallopCore.Resources.Operator do
      allow_nil?(true)
      attribute_writable?(true)
    end
  end
end
