defmodule WallopCore.DatabaseUrl do
  @moduledoc """
  Builds the database URL from `DATABASE_URL` and an optional separate
  `DATABASE_PASSWORD`.

  Keeping the password apart lets a secrets store hold it without also
  holding the host, port, user and database name, so whoever can write to
  that store can't point the app at a different database. When a password
  is given it replaces any password already in the URL, which lets the
  password move out of the URL without a moment where neither has it. It
  is percent-encoded into the URL, so any characters are fine.

  The URL is checked here rather than left to Ecto, because Ecto's own
  error for a malformed URL (including a non-numeric `timeout`,
  `pool_size` or `idle_interval` in the query) prints the whole URL,
  password included. These
  errors never include the URL or the password.
  """

  @spec build(String.t(), String.t() | nil) :: String.t()
  def build(url, nil) when is_binary(url), do: check!(url)

  def build(_url, ""), do: raise(ArgumentError, "DATABASE_PASSWORD is set but empty")

  def build(url, password) when is_binary(url) and is_binary(password) do
    uri = url |> check!() |> URI.parse()

    case uri.userinfo && String.split(uri.userinfo, ":", parts: 2) do
      [user | _] when user != "" ->
        encoded = URI.encode(password, &URI.char_unreserved?/1)
        check!(URI.to_string(%{uri | userinfo: user <> ":" <> encoded}))

      _ ->
        raise ArgumentError, "DATABASE_URL must name a user when DATABASE_PASSWORD is set"
    end
  end

  defp check!(url) do
    uri = URI.parse(url)

    cond do
      uri.host in [nil, ""] ->
        raise ArgumentError, "DATABASE_URL has no host"

      not (is_binary(uri.path) and uri.path =~ ~r"\A/[^/]+\z") ->
        raise ArgumentError, "DATABASE_URL must end with /<database name>"

      port_written?(url) and is_nil(uri.port) ->
        raise ArgumentError, "DATABASE_URL has a port that is not a number"

      not integer_settings?(uri.query) ->
        raise ArgumentError,
              "DATABASE_URL has a timeout, pool_size or idle_interval that is not a number"

      true ->
        url
    end
  end

  defp integer_settings?(nil), do: true

  defp integer_settings?(query) do
    query
    |> URI.decode_query()
    |> Enum.all?(fn {key, value} ->
      key not in ~w(timeout pool_size idle_interval) or value =~ ~r/\A\d+\z/
    end)
  end

  defp port_written?(url) do
    host_and_port =
      case String.split(url, "//", parts: 2) do
        [_scheme, rest] -> rest |> String.split(["/", "?", "#"], parts: 2) |> hd()
        _ -> ""
      end
      |> String.split("@")
      |> List.last()

    host_and_port =~ ~r/:[^\]]*\z/
  end
end
