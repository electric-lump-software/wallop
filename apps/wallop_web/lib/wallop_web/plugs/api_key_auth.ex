defmodule WallopWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Bearer token authentication by API key (ADR-0014).

  A key is looked up by its 8-character prefix and verified by comparing a
  labelled SHA-256 digest in constant time. Keys created before 0.29.0 have
  no digest yet: they are verified once with bcrypt and their digest is then
  recorded. Bcrypt is never consulted for a key that has a digest, including
  when the comparison fails.

  The digest comparison is constant-time. Response time still differs by
  path (a malformed bearer skips the database; a key with no digest yet is
  checked with bcrypt), which reveals nothing secret: prefixes are public
  (ADR-0014).
  """

  import Plug.Conn

  require Logger

  alias WallopCore.Log
  alias WallopCore.Resources.ApiKey
  alias WallopCore.Resources.ApiKey.Digest

  # `GenerateKey` uses Base.encode64(32 bytes, padding: false): 43 characters
  # of the standard alphabet.
  @key_format ~r/\Awallop_[A-Za-z0-9+\/]{43}\z/
  @dummy_key "wallop_" <> String.duplicate("A", 43)

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, raw_key} <- extract_bearer_token(conn),
         :ok <- check_format(raw_key),
         {:ok, api_key} <- find_key(raw_key),
         :ok <- verify(raw_key, api_key) do
      assign(conn, :api_key, api_key)
    else
      :error ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{errors: %{detail: "Unauthorized"}})
        |> halt()
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] -> {:ok, key}
      _ -> dummy_digest()
    end
  end

  defp check_format(raw_key) do
    if Regex.match?(@key_format, raw_key), do: :ok, else: dummy_digest()
  end

  defp find_key("wallop_" <> rest) do
    # Auth-time lookup runs without an actor (we're determining who the actor
    # IS), so it bypasses the read policy. The digest check is the auth check.
    case ApiKey
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter_input(%{key_prefix: binary_part(rest, 0, 8), active: true})
         |> Ash.read_one(domain: WallopCore.Domain, authorize?: false) do
      {:ok, %ApiKey{} = api_key} -> {:ok, api_key}
      _ -> dummy_digest()
    end
  end

  defp verify(raw_key, %ApiKey{key_digest: digest}) when is_binary(digest) do
    if Plug.Crypto.secure_compare(Digest.compute(raw_key), digest), do: :ok, else: :error
  end

  defp verify(raw_key, %ApiKey{} = api_key) do
    if Bcrypt.verify_pass(raw_key, api_key.key_hash) do
      record_digest(api_key, raw_key)
      :ok
    else
      :error
    end
  end

  # Never changes the authentication result, which bcrypt already decided.
  defp record_digest(api_key, raw_key) do
    api_key
    |> Ash.Changeset.for_update(:record_key_digest, %{key_digest: Digest.compute(raw_key)})
    |> Ash.update(domain: WallopCore.Domain, authorize?: false)
    |> case do
      {:ok, _} ->
        :telemetry.execute([:wallop_web, :api_key, :digest_recorded], %{count: 1}, %{})

      {:error, error} ->
        Logger.warning(
          "ApiKeyAuth: digest not recorded for key #{Log.redact_id(api_key.id)}: #{stale_or_inspect(error)}"
        )

        :telemetry.execute([:wallop_web, :api_key, :digest_record_failed], %{count: 1}, %{})
    end
  end

  defp stale_or_inspect(%{errors: errors} = error) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
      do: "already recorded",
      else: inspect(error)
  end

  defp stale_or_inspect(error), do: inspect(error)

  defp dummy_digest do
    Digest.compute(@dummy_key)
    :error
  end
end
