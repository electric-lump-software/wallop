defmodule WallopCore.VaultHealthCheck do
  @moduledoc """
  Boot-time sanity check for `WallopCore.Vault`.

  Performs an encrypt/decrypt round-trip with a known probe through every
  configured cipher — `:default` always, plus `:retired` when
  `VAULT_KEY_OLD` is present (see ADR-0013). Refuses to boot if any cipher
  fails to round-trip.

  Two failure modes this catches early:

    1. `VAULT_KEY` is missing or malformed → `:default` cipher cannot
       encrypt → app cannot serve writes.
    2. `VAULT_KEY_OLD` is set but malformed → `:retired` cipher cannot
       encrypt → existing rows under the old key cannot be decrypted.
       Without this check, the failure surfaces only on first read of a
       legacy row, which can be hours into a rotation.

  Also emits a structured INFO log per configured cipher reporting which
  tag it owns, and a clear WARN line when `:retired` is present so
  operators see in the boot logs that the system is in dual-key mode.
  """

  require Logger

  @probe_plaintext "wallop-vault-probe-v1"

  @doc """
  Round-trips every cipher configured on the vault. Raises on any failure.
  """
  @spec check!(module()) :: :ok
  def check!(vault_module) do
    ciphers = configured_ciphers(vault_module)

    if ciphers == [] do
      raise """
      #{inspect(vault_module)} has no configured ciphers.

      Check :wallop_core, #{inspect(vault_module)} in runtime.exs.
      """
    end

    Enum.each(ciphers, fn {label, {cipher_module, opts}} ->
      round_trip!(vault_module, label, cipher_module, opts)
    end)

    log_rotation_state(ciphers)
    :ok
  end

  defp round_trip!(vault_module, label, cipher_module, opts) do
    tag = Keyword.get(opts, :tag, "<unknown>")

    case vault_module.encrypt(@probe_plaintext, label) do
      {:ok, ciphertext} ->
        case vault_module.decrypt(ciphertext) do
          {:ok, @probe_plaintext} ->
            Logger.info(
              "Vault round-trip OK label=#{inspect(label)} cipher=#{inspect(cipher_module)} tag=#{tag}"
            )

            :ok

          {:ok, _wrong} ->
            raise """
            #{inspect(vault_module)} cipher #{inspect(label)} (#{tag}) round-trip mismatch.

            Encrypt succeeded but decrypt returned a different value.
            This should not happen — investigate immediately.
            """

          other ->
            raise """
            #{inspect(vault_module)} cipher #{inspect(label)} (#{tag}) decrypt failed: #{inspect(other)}

            Usually means iv_length is misconfigured, or the key bytes
            used to encrypt no longer match the key bytes used to decrypt.
            """
        end

      {:error, reason} ->
        raise """
        #{inspect(vault_module)} cipher #{inspect(label)} (#{tag}) encrypt failed: #{inspect(reason)}

        Check the master key for this cipher is set and decodes to 32 bytes
        of valid base64. For :default this is VAULT_KEY; for :retired this
        is VAULT_KEY_OLD.
        """
    end
  end

  # Returns the ciphers configured on the vault, as a keyword list of
  # `{label, {cipher_module, opts}}`. Reads from `Application.get_env/2`
  # because the ETS-backed live config is only populated after
  # `Vault.start_link/1` runs, and we want to be able to inspect the
  # intended ciphers regardless of boot order.
  defp configured_ciphers(WallopCore.Vault) do
    Application.get_env(:wallop_core, WallopCore.Vault, []) |> Keyword.get(:ciphers, [])
  end

  defp log_rotation_state(ciphers) do
    case Keyword.get(ciphers, :retired) do
      nil ->
        :ok

      {_module, opts} ->
        current_tag = ciphers |> Keyword.get(:default) |> elem(1) |> Keyword.get(:tag)
        retired_tag = Keyword.get(opts, :tag)

        Logger.warning("""
        Vault is in DUAL-KEY rotation mode.

          current tag (writes): #{current_tag}
          retired tag (legacy): #{retired_tag}

        VAULT_KEY_OLD is set. Once `mix wallop.vault.verify_rotation`
        reports zero previous-tag rows, drop VAULT_KEY_OLD from the
        environment and redeploy to close the rotation window.
        """)
    end
  end
end
