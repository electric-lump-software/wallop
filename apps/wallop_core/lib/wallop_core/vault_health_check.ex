defmodule WallopCore.VaultHealthCheck do
  @moduledoc """
  Verifies vault is correctly configured at startup.

  Performs an encrypt/decrypt round-trip with a known probe value.
  Call from Application.start/2 before supervised children start.
  If the vault cannot complete a round-trip, the app refuses to boot
  with a clear error message.
  """

  require Logger

  @probe_plaintext "wallop-vault-probe-v1"

  @doc """
  Asserts the given vault module can encrypt and decrypt successfully.
  Raises on failure.
  """
  @spec check!(module()) :: :ok
  def check!(vault_module) do
    with {:ok, ciphertext} <- vault_module.encrypt(@probe_plaintext),
         {:ok, decrypted} <- vault_module.decrypt(ciphertext),
         true <- decrypted == @probe_plaintext do
      :ok
    else
      _ ->
        raise """
        #{inspect(vault_module)} failed its startup health check.

        The vault cannot complete an encrypt/decrypt round-trip.
        This means either VAULT_KEY is wrong, or iv_length is
        misconfigured between services sharing the same database.

        Check that VAULT_KEY is set correctly and that all services
        use iv_length: 12 in their Cloak cipher config.
        """
    end
  end
end
