defmodule WallopCore.Resources.Draw.CheckUrl do
  @moduledoc """
  Validates the optional `metadata.check_url` field — the operator's
  own "check your ticket" page that the public proof page links to.

  Unlike `callback_url` (a webhook target that wallop actually POSTs
  to), `check_url` is a user-facing link that wallop NEVER fetches
  server-side. SSRF concerns don't apply. But XSS does: a malicious
  operator could supply `javascript:alert(1)` or a `data:` URL and
  get it rendered into an `<a href>` on someone else's proof page.

  Rules:
  - Must be an `https://` URL.
  - Must have a non-empty host.
  - Must not exceed 2048 characters.
  - No `javascript:`, `data:`, `vbscript:`, `file:`, `ftp:`, etc.

  Returns `:ok` or `{:error, reason}`.
  """

  @max_length 2048

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(url) when is_binary(url) do
    if String.length(url) > @max_length do
      {:error, "must be at most #{@max_length} characters"}
    else
      parse_and_check(url)
    end
  end

  def validate(_), do: {:error, "must be a string"}

  defp parse_and_check(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        :ok

      %URI{scheme: scheme} when scheme in ["http", nil] ->
        {:error, "must be an https:// URL"}

      _ ->
        {:error, "must be an https:// URL"}
    end
  end
end
