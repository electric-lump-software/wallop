defmodule WallopCore.VaultKeyCheck do
  @moduledoc """
  Proves at boot that each configured vault key is the key the stored rows
  were written with, not just a well-formed key.

  For each configured cipher (`:default`, plus `:retired` while
  `VAULT_KEY_OLD` is set) it takes one signing-key row whose ciphertext
  carries that cipher's tag, from `infrastructure_signing_keys` or else
  `operator_signing_keys`. It decrypts the private key and checks it against
  the row's public key and `key_id` with `WallopCore.Protocol.assert_key_consistency/3`,
  as signing does. Any failure raises. A tag that no row carries (a fresh
  install) is skipped with a log line.

  It runs as a child of `WallopCore.Application` after `WallopCore.Vault`
  and before Oban. Its start function runs the check and returns `:ignore`,
  so a failure stops the supervisor before any job can run.

  Messages name the table, the row's public `key_id`, the tag and an error
  atom. They never carry key bytes, ciphertext or a decrypt result.
  `WallopCore.VaultHealthCheck` stays as the cheap round-trip probe.
  """

  require Ash.Query
  require Logger

  alias WallopCore.Protocol
  alias WallopCore.Resources.{InfrastructureSigningKey, OperatorSigningKey}

  @sources [
    {InfrastructureSigningKey, "infrastructure_signing_keys"},
    {OperatorSigningKey, "operator_signing_keys"}
  ]

  @type outcome :: {:ok, table :: String.t(), key_id :: String.t()} | :skipped
  @type result :: {label :: atom(), tag :: String.t(), outcome()}

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Runs `check!/1`, then returns `:ignore`: nothing stays running."
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    check!(opts)
    :ignore
  end

  @doc """
  Checks every configured cipher against a stored row. Raises on the first
  failure; otherwise returns one result per cipher.

  Options (for tests): `:vault` (default `WallopCore.Vault`) and `:ciphers`
  (default: the vault's configured cipher list).
  """
  @spec check!(keyword()) :: [result()]
  def check!(opts \\ []) do
    vault = Keyword.get(opts, :vault, WallopCore.Vault)
    ciphers = Keyword.get_lazy(opts, :ciphers, &configured_ciphers/0)

    Enum.map(ciphers, fn {label, {_module, cipher_opts}} ->
      check_cipher!(vault, label, Keyword.fetch!(cipher_opts, :tag))
    end)
  end

  defp check_cipher!(vault, label, tag) do
    case find_row(tag) do
      nil ->
        Logger.info(
          "Vault key check skipped cipher #{inspect(label)} (#{tag}): no signing key row carries this tag"
        )

        {label, tag, :skipped}

      {table, row} ->
        case verify(vault, row) do
          :ok ->
            Logger.info(
              "Vault key check passed: cipher #{inspect(label)} (#{tag}) decrypted #{table} key_id=#{row.key_id}"
            )

            {label, tag, {:ok, table, row.key_id}}

          {:error, reason} ->
            raise """
            Vault key check failed: cipher #{inspect(label)} (#{tag}) on #{table} key_id=#{row.key_id}: #{inspect(reason)}.

            The configured key is not the key this row was written with
            (VAULT_KEY for :default, VAULT_KEY_OLD for :retired), or the row's
            public key does not match its private key. Refusing to start.
            """
        end
    end
  end

  # Cloak's AES-GCM returns `{:ok, :error}` when authentication fails, so a
  # wrong key surfaces as a non-binary "plaintext".
  defp verify(vault, row) do
    case vault.decrypt(row.private_key) do
      {:ok, seed} when is_binary(seed) -> consistent(row, seed)
      _error -> {:error, :decrypt_failed}
    end
  end

  defp consistent(%{public_key: public_key, key_id: key_id}, seed)
       when byte_size(seed) == 32 and byte_size(public_key) == 32 and is_binary(key_id) and
              key_id != "" do
    Protocol.assert_key_consistency(public_key, seed, key_id)
  end

  defp consistent(_row, _seed), do: {:error, :malformed_key}

  defp find_row(tag) do
    prefix = <<1, byte_size(tag)>> <> tag

    Enum.find_value(@sources, fn {resource, table} ->
      case first_row_with_prefix(resource, prefix) do
        {:ok, nil} -> nil
        {:ok, row} -> {table, row}
        {:error, error} -> raise "Vault key check could not read #{table}: #{error_kind(error)}"
      end
    end)
  end

  defp first_row_with_prefix(resource, prefix) do
    size = byte_size(prefix)

    resource
    |> Ash.Query.filter(fragment("substring(? from 1 for ?) = ?", private_key, ^size, ^prefix))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end

  defp error_kind(%module{}), do: inspect(module)

  defp configured_ciphers do
    :wallop_core |> Application.get_env(WallopCore.Vault, []) |> Keyword.get(:ciphers, [])
  end
end
