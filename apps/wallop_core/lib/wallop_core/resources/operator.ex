defmodule WallopCore.Resources.Operator do
  @moduledoc """
  An operator is the public-facing identity that locks draws.

  Operators are the unit of cross-draw verifiability: every draw locked by an
  api_key belonging to an operator gets a gap-free sequence number and a signed
  commitment receipt. The operator's public registry at `/operator/:slug` lists
  every draw they've ever locked — open, completed, expired, or failed —
  making sequential draw shopping detectable.

  See `WallopCore.Resources.OperatorSigningKey` and
  `WallopCore.Resources.OperatorReceipt`.
  """

  use Ash.Resource,
    otp_app: :wallop_core,
    domain: WallopCore.Domain,
    data_layer: AshPostgres.DataLayer

  @reserved_slugs ~w(
    api admin assets dev key keys live operator operators proof receipts
    transparency wallop www
  )

  postgres do
    table("operators")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:slug, :name])

      validate(fn changeset, _ ->
        slug = Ash.Changeset.get_attribute(changeset, :slug) || ""

        cond do
          slug == "" ->
            {:error, field: :slug, message: "is required"}

          slug in unquote(@reserved_slugs) ->
            {:error, field: :slug, message: "is reserved"}

          not Regex.match?(~r/^[a-z0-9][a-z0-9-]{1,62}$/, slug) ->
            {:error,
             field: :slug,
             message: "must be lowercase alphanumeric with hyphens, 2-63 chars"}

          true ->
            :ok
        end
      end)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :slug, :ci_string do
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 255)
    end

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  relationships do
    has_many :api_keys, WallopCore.Resources.ApiKey do
      destination_attribute(:operator_id)
    end

    has_many :signing_keys, WallopCore.Resources.OperatorSigningKey do
      destination_attribute(:operator_id)
    end

    has_many :receipts, WallopCore.Resources.OperatorReceipt do
      destination_attribute(:operator_id)
    end
  end
end
