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
  Raises on failure with a specific message indicating which step failed.
  """
  @spec check!(module()) :: :ok
  def check!(vault_module) do
    case vault_module.encrypt(@probe_plaintext) do
      {:ok, ciphertext} ->
        case vault_module.decrypt(ciphertext) do
          {:ok, @probe_plaintext} ->
            Logger.info("Vault health check passed for #{inspect(vault_module)}")
            :ok

          {:ok, _wrong} ->
            raise """
            #{inspect(vault_module)} round-trip mismatch.

            Encrypt succeeded but decrypt returned a different value.
            This should not happen — investigate immediately.
            """

          other ->
            raise """
            #{inspect(vault_module)} decrypt failed after successful encrypt: #{inspect(other)}

            This usually means iv_length is misconfigured between
            encrypt and decrypt, or the vault restarted with a
            different key between the two calls.
            """
        end

      {:error, reason} ->
        raise """
        #{inspect(vault_module)} encrypt failed: #{inspect(reason)}

        Check that VAULT_KEY is set and the vault process is started.
        """
    end
  end
end
