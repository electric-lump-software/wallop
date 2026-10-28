defmodule WallopCore.DatabaseUrl do
  @moduledoc """
  Builds the database URL from `DATABASE_URL` and an optional separate
  `DATABASE_PASSWORD`.

  Keeping the password apart lets a secrets store hold it without also
  holding the host, port, user and database name, so whoever can write to
  that store can't point the app at a different database. When a password
  is given it replaces any password already in the URL, which lets the
  password move out of the URL without a moment where neither has it.

  Ecto reads the password from the URL without percent-decoding it, so the
  password is limited to characters that need no escaping in a URL. Errors
  never include the URL or the password.
  """

  @spec build(String.t(), String.t() | nil) :: String.t()
  def build(url, nil), do: url

  def build(url, password) when is_binary(url) and is_binary(password) do
    unless password =~ ~r/\A[A-Za-z0-9._~-]+\z/ do
      raise ArgumentError,
            "DATABASE_PASSWORD must be non-empty and use only letters, digits and . _ ~ -"
    end

    uri = URI.parse(url)

    case uri.userinfo && String.split(uri.userinfo, ":", parts: 2) do
      [user | _] when user != "" ->
        URI.to_string(%{uri | userinfo: user <> ":" <> password})

      _ ->
        raise ArgumentError, "DATABASE_URL must name a user when DATABASE_PASSWORD is set"
    end
  end
end
