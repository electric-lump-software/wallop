defmodule Mix.Tasks.Wallop.RotateInfrastructureKey do
  @moduledoc """
  Rotate the wallop infrastructure Ed25519 signing key.

  ## Usage

      mix wallop.rotate_infrastructure_key

  Generates a new Ed25519 keypair and inserts it with `valid_from: now()`.
  New execution receipts are signed with it immediately. The old key stays
  published until `WallopCore.KeyRotation.revoke_superseded_keys/0` revokes
  it.

  Delegates to `WallopCore.KeyRotation.rotate_infrastructure_key/0`, which a
  running release can call directly with `bin/wallop rpc`.

  Run `mix wallop.bootstrap_infrastructure_key` first if no key exists yet.
  """
  use Mix.Task

  @shortdoc "Rotate the wallop infrastructure Ed25519 signing key"

  def run(_args) do
    Mix.Task.run("app.start")

    case WallopCore.KeyRotation.rotate_infrastructure_key() do
      {:ok, _new_key} ->
        :ok

      {:error, :no_infrastructure_key} ->
        Mix.shell().error("""
        No infrastructure key exists yet.
        Run `mix wallop.bootstrap_infrastructure_key` first.
        """)

      {:error, reason} ->
        Mix.raise("Infrastructure key rotation failed: #{inspect(reason)}")
    end
  end
end
