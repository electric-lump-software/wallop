defmodule WallopCore.Resources.ApiKey.Changes.GenerateKey do
  @moduledoc "Generates a random API key, stores its bcrypt hash and prefix."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    random_bytes = :crypto.strong_rand_bytes(32)
    random_part = Base.encode64(random_bytes, padding: false)
    raw_key = "wallop_" <> random_part
    prefix = String.slice(random_part, 0, 8)
    hash = Bcrypt.hash_pwd_salt(raw_key)

    webhook_secret = :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)

    encrypted_secret =
      case WallopCore.Vault.encrypt(webhook_secret) do
        {:ok, enc} -> enc
        {:error, _} -> raise "Vault encrypt failed — check VAULT_KEY config"
      end

    encoded_secret = Base.encode64(encrypted_secret)

    changeset
    |> Ash.Changeset.force_change_attribute(:key_hash, hash)
    |> Ash.Changeset.force_change_attribute(:key_prefix, prefix)
    |> Ash.Changeset.force_change_attribute(:webhook_secret, encoded_secret)
    |> Ash.Changeset.after_action(fn _changeset, api_key ->
      api_key =
        api_key
        |> Ash.Resource.put_metadata(:raw_key, raw_key)
        |> Ash.Resource.put_metadata(:raw_webhook_secret, webhook_secret)

      {:ok, api_key}
    end)
  end
end
