defmodule WallopCore.Resources.ApiKey.Changes.RegenerateWebhookSecret do
  @moduledoc """
  Generates a new webhook secret, encrypts it, and overwrites the existing one.

  The raw (unencrypted) secret is returned via metadata — shown once, never stored.
  The old secret is immediately invalidated.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    webhook_secret = :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)

    encrypted_secret =
      case WallopCore.Vault.encrypt(webhook_secret) do
        {:ok, enc} -> enc
        {:error, _} -> raise "Vault encrypt failed — check VAULT_KEY config"
      end

    encoded_secret = Base.encode64(encrypted_secret)

    changeset
    |> Ash.Changeset.force_change_attribute(:webhook_secret, encoded_secret)
    |> Ash.Changeset.after_action(fn _changeset, api_key ->
      api_key = Ash.Resource.put_metadata(api_key, :raw_webhook_secret, webhook_secret)
      {:ok, api_key}
    end)
  end
end
