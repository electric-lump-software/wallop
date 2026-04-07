defmodule WallopCore.Resources.Operator do
  @moduledoc """
  An operator is the public-facing identity that locks draws.

  Two fields define an operator:

  - `slug` — the **canonical identity**. Citext, unique, immutable forever.
    Embedded as `operator_slug` in every signed receipt JCS payload, so it
    is part of the cryptographic commitment. Renaming would invalidate every
    previously published receipt — there is no API to do so.

  - `name` — a **display label only**. Free text, mutable, never embedded in
    a signed payload. Anywhere wallop_web renders `name`, the slug must
    appear adjacent so users learn the slug is the thing they verify.

  ## Protocol invariant

  `name` MUST NOT appear in any signed payload, hashed artifact, Merkle leaf,
  or transparency anchor — ever. If a future schema bumps need a display
  string, mint a new field and bump `schema_version`. Don't sneak `name` in.

  Operators are the unit of cross-draw verifiability: every draw locked by an
  api_key belonging to an operator gets a gap-free sequence number and a
  signed commitment receipt. The operator's public registry at
  `/operator/:slug` lists every draw they've ever locked — open, completed,
  expired, or failed — making sequential draw shopping detectable.

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

  @max_name_length 80

  postgres do
    table("operators")
    repo(WallopCore.Repo)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:slug, :name])

      validate(fn changeset, _ ->
        slug = changeset |> Ash.Changeset.get_attribute(:slug) |> to_string()

        with :ok <- validate_slug(slug) do
          validate_name(Ash.Changeset.get_attribute(changeset, :name))
        end
      end)

      change(fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :name) do
          nil ->
            slug = changeset |> Ash.Changeset.get_attribute(:slug) |> to_string()
            Ash.Changeset.force_change_attribute(changeset, :name, slug)

          _ ->
            changeset
        end
      end)
    end

    update :update_name do
      accept([:name])

      validate(fn changeset, _ ->
        validate_name(Ash.Changeset.get_attribute(changeset, :name))
      end)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :slug, :ci_string do
      description("Canonical identity. Immutable. Embedded in every signed receipt.")
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      description("Display label only. Mutable. Never in any signed payload.")
      allow_nil?(false)
      public?(true)
      constraints(max_length: @max_name_length)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
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

  defp validate_slug(slug) do
    cond do
      slug == "" ->
        {:error, field: :slug, message: "is required"}

      slug in @reserved_slugs ->
        {:error, field: :slug, message: "is reserved"}

      not Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/, slug) or
          String.length(slug) < 2 ->
        {:error, field: :slug, message: "must be lowercase alphanumeric with hyphens, 2-63 chars"}

      true ->
        :ok
    end
  end

  defp validate_name(nil), do: :ok
  defp validate_name(""), do: {:error, field: :name, message: "must not be blank"}

  defp validate_name(name) when is_binary(name) do
    case :unicode.characters_to_nfc_binary(name) do
      normalised when is_binary(normalised) -> validate_normalised_name(normalised)
      _ -> {:error, field: :name, message: "must be valid Unicode"}
    end
  end

  defp validate_normalised_name(name) do
    cond do
      String.length(name) > @max_name_length ->
        {:error, field: :name, message: "must be at most #{@max_name_length} characters"}

      contains_disallowed_chars?(name) ->
        {:error, field: :name, message: "must not contain control or invisible/bidi codepoints"}

      true ->
        :ok
    end
  end

  # Reject anything that lets a display name be invisible, ambiguous, or
  # spoof another operator's name visually.
  defp contains_disallowed_chars?(name) do
    Enum.any?(String.to_charlist(name), fn cp ->
      # ASCII soft hyphen
      # Zero-width space, ZWNJ, ZWJ
      # Line/paragraph separators
      # Bidi formatting (LRE, RLE, PDF, LRO, RLO)
      # Bidi isolates (LRI, RLI, FSI, PDI)
      # Byte order mark / zero-width no-break space
      # Tag block — used in some homograph attacks
      cp < 0x20 or
        cp == 0x7F or
        cp == 0x00AD or
        cp in 0x200B..0x200D or
        cp in 0x2028..0x2029 or
        cp in 0x202A..0x202E or
        cp in 0x2066..0x2069 or
        cp == 0xFEFF or
        cp in 0xE0000..0xE007F
    end)
  end
end
