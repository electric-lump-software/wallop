defmodule WallopWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Bearer token authentication by API key.

  A key is looked up by its 8-character prefix and verified by comparing a
  labelled SHA-256 digest in constant time. Keys created before 0.29.0 have
  no digest yet: they are verified once with bcrypt and their digest is then
  recorded. Bcrypt is never consulted for a key that has a digest, including
  when the comparison fails.

  The digest comparison is constant-time. Response time still differs by
  path (a malformed bearer skips the database; a key with no digest yet is
  checked with bcrypt), which reveals nothing secret: prefixes are public.

  Failures count against the caller's IP (`WallopWeb.IpAuthLimit`). Once over
  the limit, failures get a 429, and keys without a digest are refused before
  bcrypt. A key that matches by digest is never refused by the IP limit.
  """

  import Plug.Conn

  require Logger

  alias WallopCore.Log
  alias WallopCore.Resources.ApiKey
  alias WallopCore.Resources.ApiKey.Digest
  alias WallopWeb.IpAuthLimit
  alias WallopWeb.RateLimitResponse

  # `GenerateKey` uses Base.encode64(32 bytes, padding: false): 43 characters
  # of the standard alphabet.
  @key_format ~r/\Awallop_[A-Za-z0-9+\/]{43}\z/
  @dummy_key "wallop_" <> String.duplicate("A", 43)

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, raw_key} <- extract_bearer_token(conn),
         :ok <- check_format(raw_key),
         {:ok, api_key} <- find_key(raw_key),
         :ok <- verify(conn, raw_key, api_key) do
      assign(conn, :api_key, api_key)
    else
      {:deny, retry_after} -> too_many_failures(conn, retry_after)
      :counted_error -> unauthorized(conn)
      :error -> fail(conn)
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

  defp verify(_conn, raw_key, %ApiKey{key_digest: digest}) when is_binary(digest) do
    if Plug.Crypto.secure_compare(Digest.compute(raw_key), digest), do: :ok, else: :error
  end

  # No digest yet: bcrypt is expensive, so the attempt is counted against the
  # IP before it runs (one atomic increment-and-compare) and an IP over its
  # limit is refused without running it. A bcrypt failure is not counted again
  # (`:counted_error`); a success keeps its slot.
  defp verify(conn, raw_key, %ApiKey{} = api_key) do
    with :ok <- IpAuthLimit.record_failure(conn.remote_ip) do
      if Bcrypt.verify_pass(raw_key, api_key.key_hash) do
        record_digest(api_key, raw_key)
        :ok
      else
        :counted_error
      end
    end
  end

  defp fail(conn) do
    case IpAuthLimit.record_failure(conn.remote_ip) do
      :ok -> unauthorized(conn)
      {:deny, retry_after} -> too_many_failures(conn, retry_after)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{errors: %{detail: "Unauthorized"}})
    |> halt()
  end

  defp too_many_failures(conn, retry_after) do
    RateLimitResponse.send_429(
      conn,
      retry_after,
      "ip_rate_limit_exceeded",
      "Too many failed authentications from this address. Retry after #{retry_after} seconds."
    )
  end

  # Never changes the authentication result, which bcrypt already decided.
  # A concurrent first request recording the digest first (StaleRecord) is a
  # normal race and counts as success. Exposed for tests only.
  @doc false
  def record_digest(api_key, raw_key) do
    api_key
    |> Ash.Changeset.for_update(:record_key_digest, %{key_digest: Digest.compute(raw_key)})
    |> Ash.update(domain: WallopCore.Domain, authorize?: false)
    |> case do
      {:ok, _} ->
        digest_recorded(:recorded)

      {:error, error} ->
        if stale_record?(error) do
          Logger.info("ApiKeyAuth: digest already recorded for key #{Log.redact_id(api_key.id)}")
          digest_recorded(:already_recorded)
        else
          # Error classes only: a leaf error's value could carry the digest.
          Logger.warning(
            "ApiKeyAuth: digest not recorded for key #{Log.redact_id(api_key.id)}: #{error_classes(error)}"
          )

          :telemetry.execute([:wallop_web, :api_key, :digest_record_failed], %{count: 1}, %{})
        end
    end

    :ok
  end

  defp digest_recorded(outcome) do
    :telemetry.execute([:wallop_web, :api_key, :digest_recorded], %{count: 1}, %{
      outcome: outcome
    })
  end

  defp stale_record?(%{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

  defp stale_record?(_), do: false

  defp error_classes(%{errors: errors} = error) when is_list(errors),
    do: inspect([error.__struct__ | Enum.map(errors, & &1.__struct__)])

  defp error_classes(%{__struct__: module}), do: inspect(module)

  defp dummy_digest do
    Digest.compute(@dummy_key)
    :error
  end
end
