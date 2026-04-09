defmodule Mix.Tasks.Wallop.BootstrapInfrastructureKey do
  @moduledoc """
  Generate the first wallop infrastructure Ed25519 signing keypair.

  ## Usage

      mix wallop.bootstrap_infrastructure_key

  Run once at first deploy. The key is Vault-encrypted at rest. Subsequent
  rotation uses `mix wallop.rotate_infrastructure_key`.

  The infrastructure key signs execution receipts — a separate concern from
  operator signing keys which sign commitment (lock) receipts. See
  `spec/design-drafts/execution-receipt.md` for the design rationale.
  """
  use Mix.Task

  alias WallopCore.Protocol
  alias WallopCore.Resources.InfrastructureSigningKey
  alias WallopCore.Vault

  @shortdoc "Generate the wallop infrastructure Ed25519 signing keypair"

  def run(_args) do
    Mix.Task.run("app.start")

    # Check if a key already exists
    case InfrastructureSigningKey
         |> Ash.Query.sort(valid_from: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, [existing]} ->
        Mix.shell().error("""
        An infrastructure key already exists (key_id: #{existing.key_id}).
        Use `mix wallop.rotate_infrastructure_key` to rotate.
        """)

      {:ok, []} ->
        create_key()

      {:error, reason} ->
        Mix.shell().error("Failed to check existing keys: #{inspect(reason)}")
    end
  end

  defp create_key do
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

    Infrastructure signing key created:

      key_id:    #{key_id}
      pubkey:    #{Base.encode16(public_key, case: :lower)}

    This key signs execution receipts. Publish the public key at
    GET /infrastructure/key so verifiers can check execution attestations.

    To rotate: mix wallop.rotate_infrastructure_key
    """)
  end
end
