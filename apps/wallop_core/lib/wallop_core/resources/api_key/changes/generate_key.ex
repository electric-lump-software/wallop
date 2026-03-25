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

    changeset
    |> Ash.Changeset.force_change_attribute(:key_hash, hash)
    |> Ash.Changeset.force_change_attribute(:key_prefix, prefix)
    |> Ash.Changeset.after_action(fn _changeset, api_key ->
      {:ok, Ash.Resource.put_metadata(api_key, :raw_key, raw_key)}
    end)
  end
end
