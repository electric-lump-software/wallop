defmodule Mix.Tasks.Wallop.RotateInfrastructureKey do
  @moduledoc """
  Rotate the wallop infrastructure Ed25519 signing key.

  ## Usage

      mix wallop.rotate_infrastructure_key

  Generates a new Ed25519 keypair and inserts it with `valid_from: now()`.
  The old key remains forever — historical execution receipts continue to
  verify under it.

  After rotation, new execution receipts are signed with the new key.
  The transition is immediate: the "current" key is always the row with
  the largest `valid_from <= now()`.

  Run `mix wallop.bootstrap_infrastructure_key` first if no key exists yet.
  """
  use Mix.Task

  require Ash.Query

  alias WallopCore.Protocol
  alias WallopCore.Resources.InfrastructureSigningKey
  alias WallopCore.Vault

  @shortdoc "Rotate the wallop infrastructure Ed25519 signing key"

  def run(_args) do
    Mix.Task.run("app.start")

    case current_key() do
      {:ok, old_key} ->
        rotate(old_key)

      :none ->
        Mix.shell().error("""
        No infrastructure key exists yet.
        Run `mix wallop.bootstrap_infrastructure_key` first.
        """)
    end
  end

  defp rotate(old_key) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = Protocol.key_id(public_key)
    {:ok, encrypted_private} = Vault.encrypt(private_key)

    {:ok, _key} =
      InfrastructureSigningKey
      |> Ash.Changeset.for_create(:create, %{
        key_id: key_id,
        public_key: public_key,
        private_key: encrypted_private,
        valid_from: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    IO.puts("""

    Infrastructure key rotated.

      old key_id:  #{old_key.key_id}
      new key_id:  #{key_id}
      new pubkey:  #{Base.encode16(public_key, case: :lower)}

    The old key remains in the database — historical execution receipts
    still verify under it. New receipts use the new key immediately.
    """)
  end

  defp current_key do
    now = DateTime.utc_now()

    InfrastructureSigningKey
    |> Ash.Query.filter(valid_from <= ^now)
    |> Ash.Query.sort(valid_from: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [key] -> {:ok, key}
      [] -> :none
    end
  end
end
