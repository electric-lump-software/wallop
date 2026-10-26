defmodule WallopCore.KeyRotation do
  @moduledoc """
  Signing-key rotation and revocation, callable from a running release:

      bin/wallop rpc 'WallopCore.KeyRotation.rotate_infrastructure_key()'
      bin/wallop rpc 'WallopCore.KeyRotation.rotate_operator_key("acme-prizes")'
      bin/wallop rpc 'WallopCore.KeyRotation.revoke_superseded_keys()'

  Rotation inserts a new key with `valid_from` now, which becomes the
  current key on the next signature. Revocation withdraws every key that is
  not current: it stops being published and can no longer verify, so proofs
  signed under it fail. Neither ever revokes the key that is signing now.

  Output is key ids and public keys only.
  """

  require Ash.Query

  alias WallopCore.Protocol
  alias WallopCore.Repo

  alias WallopCore.Resources.{
    InfrastructureSigningKey,
    Operator,
    OperatorSigningKey,
    SigningKeyRevocation
  }

  alias WallopCore.Vault

  @revocation_reason "superseded"

  @type new_key :: %{key_id: String.t(), public_key_hex: String.t()}

  @doc """
  Adds a new infrastructure signing key. Refuses when none exists yet:
  bootstrap the first one with `mix wallop.bootstrap_infrastructure_key`.
  """
  @spec rotate_infrastructure_key() :: {:ok, new_key} | {:error, term()}
  def rotate_infrastructure_key do
    with {:ok, _current} <- current_infrastructure_key(),
         {:ok, key} <- insert_key(InfrastructureSigningKey, %{}) do
      announce("infrastructure", key)
    end
  end

  @doc "Adds a new signing key for the operator with this slug."
  @spec rotate_operator_key(String.t()) :: {:ok, new_key} | {:error, term()}
  def rotate_operator_key(slug) when is_binary(slug) do
    with {:ok, operator} <- operator_by_slug(slug),
         {:ok, key} <- insert_key(OperatorSigningKey, %{operator_id: operator.id}) do
      announce("operator #{slug}", key)
    end
  end

  @doc """
  Revokes every unrevoked key that is not the current key of its class
  (infrastructure) or of its operator. A class or operator with no current
  key is left alone, so this cannot stop anything from signing. Running it
  again revokes nothing.

  Refuses, revoking nothing, while any unrevoked key has a `valid_from`
  later than this node's clock: that key is about to become current, and
  revoking around it would withdraw it instead of the key it replaces.
  Run it again once the key is valid.
  """
  @spec revoke_superseded_keys() ::
          {:ok,
           %{
             count: non_neg_integer(),
             infrastructure: [String.t()],
             operator: [%{operator_id: String.t(), key_id: String.t()}]
           }}
          | {:error, {:future_dated_keys, [String.t()]}}
  def revoke_superseded_keys do
    Repo.transaction(fn ->
      now = DateTime.utc_now()
      infrastructure_keys = Ash.read!(InfrastructureSigningKey, authorize?: false)
      operator_keys = Ash.read!(OperatorSigningKey, authorize?: false)

      case Enum.filter(
             infrastructure_keys ++ operator_keys,
             &(DateTime.compare(&1.valid_from, now) == :gt)
           ) do
        [] -> :ok
        future -> Repo.rollback({:future_dated_keys, Enum.map(future, & &1.key_id)})
      end

      infrastructure =
        infrastructure_keys
        |> superseded(now)
        |> Enum.map(&revoke!(:infrastructure, nil, &1.key_id))

      operator =
        operator_keys
        |> Enum.group_by(& &1.operator_id)
        |> Enum.flat_map(fn {_operator_id, keys} -> superseded(keys, now) end)
        |> Enum.map(fn key ->
          revoke!(:operator, key.operator_id, key.key_id)
          %{operator_id: key.operator_id, key_id: key.key_id}
        end)

      %{
        count: length(infrastructure) + length(operator),
        infrastructure: infrastructure,
        operator: operator
      }
    end)
  end

  @doc "The infrastructure key that signs now: the largest `valid_from <= now`."
  @spec current_infrastructure_key() :: {:ok, struct()} | {:error, :no_infrastructure_key}
  def current_infrastructure_key do
    now = DateTime.utc_now()

    InfrastructureSigningKey
    |> Ash.Query.filter(valid_from <= ^now)
    |> Ash.Query.sort(valid_from: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [key] -> {:ok, key}
      [] -> {:error, :no_infrastructure_key}
    end
  end

  defp superseded(keys, now) do
    case current_of(keys, now) do
      nil -> []
      current -> Enum.reject(keys, &(&1.id == current.id))
    end
  end

  defp current_of(keys, now) do
    keys
    |> Enum.filter(&(DateTime.compare(&1.valid_from, now) != :gt))
    |> Enum.max_by(& &1.valid_from, DateTime, fn -> nil end)
  end

  defp revoke!(key_class, operator_id, key_id) do
    SigningKeyRevocation
    |> Ash.Changeset.for_create(:create, %{
      key_class: key_class,
      operator_id: operator_id,
      key_id: key_id,
      reason: @revocation_reason
    })
    |> Ash.create!(authorize?: false)

    key_id
  end

  defp operator_by_slug(slug) do
    Operator
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Operator{} = operator} -> {:ok, operator}
      {:ok, nil} -> {:error, :operator_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp insert_key(resource, attrs) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = Protocol.key_id(public_key)

    with {:ok, encrypted_private} <- Vault.encrypt(private_key) do
      resource
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(attrs, %{
          key_id: key_id,
          public_key: public_key,
          private_key: encrypted_private,
          valid_from: DateTime.utc_now()
        })
      )
      |> Ash.create(authorize?: false)
    end
  end

  defp announce(label, key) do
    new_key = %{key_id: key.key_id, public_key_hex: Base.encode16(key.public_key, case: :lower)}

    IO.puts("""
    New #{label} signing key:
      key_id:  #{new_key.key_id}
      pubkey:  #{new_key.public_key_hex}
    """)

    {:ok, new_key}
  end
end
