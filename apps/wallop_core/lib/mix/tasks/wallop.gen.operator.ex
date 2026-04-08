defmodule Mix.Tasks.Wallop.Gen.Operator do
  @moduledoc """
  Generate a new operator and its first Ed25519 signing keypair.

  ## Usage

      mix wallop.gen.operator SLUG NAME

  ## Example

      mix wallop.gen.operator acme-prizes "Acme Prizes Ltd"

  Prints the operator id, slug, key id (fingerprint), and the public key in
  hex. Publish the fingerprint out-of-band (your README, blog, social) so
  verifiers can bind the wallop-held key to your externally-attested identity.
  """
  use Mix.Task

  alias WallopCore.Protocol
  alias WallopCore.Resources.{Operator, OperatorSigningKey}
  alias WallopCore.Vault

  @shortdoc "Generate a new operator with an Ed25519 signing keypair"

  def run([slug, name | _]) do
    Mix.Task.run("app.start")

    {:ok, operator} =
      Operator
      |> Ash.Changeset.for_create(:create, %{slug: slug, name: name})
      |> Ash.create(authorize?: false)

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = Protocol.key_id(public_key)
    {:ok, encrypted_private} = Vault.encrypt(private_key)

    {:ok, _signing_key} =
      OperatorSigningKey
      |> Ash.Changeset.for_create(:create, %{
        operator_id: operator.id,
        key_id: key_id,
        public_key: public_key,
        private_key: encrypted_private,
        valid_from: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    IO.puts("""

    Operator created:

      id:        #{operator.id}
      slug:      #{operator.slug}
      name:      #{operator.name}

    First signing key:

      key_id:    #{key_id}
      pubkey:    #{Base.encode16(public_key, case: :lower)}

    Public registry:    /operator/#{operator.slug}
    Receipts:           /operator/#{operator.slug}/receipts
    Public key:         /operator/#{operator.slug}/key

    Publish the key_id (#{key_id}) out-of-band so verifiers can bind it to
    your externally-attested identity.
    """)
  end

  def run(_) do
    Mix.shell().error("Usage: mix wallop.gen.operator SLUG NAME")
  end
end
