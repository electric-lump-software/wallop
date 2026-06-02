defmodule WallopCore.Vault do
  @moduledoc """
  Cloak vault for encrypting sensitive fields at rest.

  Three resources encrypt one column each through this vault:

    * `OperatorSigningKey.private_key` — Ed25519 signing key, raw bytes.
    * `InfrastructureSigningKey.private_key` — Ed25519 signing key, raw.
    * `ApiKey.webhook_secret` — base64-encoded ciphertext (the column is
      typed `:string`, so encryption output is base64-wrapped before
      storage; everywhere else is `:binary` and stores ciphertext raw).

  ## Cipher selection and routing

  Cipher list is built by `WallopCore.Vault.Config.build_ciphers/2` and
  supplied through `runtime.exs`. Routing rules:

    * **Encrypt:** Cloak always uses the FIRST cipher in the list
      (`:default`), regardless of which label is currently active.
    * **Decrypt:** Cloak inspects the ciphertext's tag prefix and routes
      to the cipher whose `:tag` matches. This is what lets a single
      vault decrypt rows from multiple generations of key material.

  ## Dual-key rotation (ADR-0013)

  When `VAULT_KEY_OLD` is set in the environment, the vault is
  configured with TWO ciphers — `:default` and `:retired`. New writes
  flow through `:default` (new key, new tag); existing rows are
  decrypted by `:retired` (old key, old tag).

  See `WallopCore.Vault.Config` for the cipher-list builder and the
  step-by-step rotation procedure. The companion inspection task is
  `mix wallop.vault.verify_rotation` — read-only report on how many
  rows still carry the previous tag.

  Boot-time round-trip verification of every configured cipher is in
  `WallopCore.VaultHealthCheck`.
  """

  use Cloak.Vault, otp_app: :wallop_core
end
