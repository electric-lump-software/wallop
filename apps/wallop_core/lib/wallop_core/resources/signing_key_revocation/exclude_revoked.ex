defmodule WallopCore.Resources.SigningKeyRevocation.ExcludeRevoked do
  @moduledoc """
  Read preparation on the signing-key resources: drops every key that has a
  `SigningKeyRevocation`. It sits on the resource, so every read action and
  relationship load excludes revoked keys without each call site asking.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  alias WallopCore.Resources.SigningKeyRevocation

  @impl true
  def prepare(query, opts, _context) do
    case Keyword.fetch!(opts, :key_class) do
      :infrastructure ->
        Ash.Query.filter(
          query,
          not exists(
            SigningKeyRevocation,
            key_class == :infrastructure and key_id == parent(key_id)
          )
        )

      :operator ->
        Ash.Query.filter(
          query,
          not exists(
            SigningKeyRevocation,
            key_class == :operator and operator_id == parent(operator_id) and
              key_id == parent(key_id)
          )
        )
    end
  end
end
