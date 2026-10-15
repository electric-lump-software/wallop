defmodule WallopWeb.Plugs.CanonicalUrl do
  @moduledoc """
  Makes `conn.scheme`, `conn.host` and `conn.port` match the endpoint's
  configured public URL when that URL is `https`.

  TLS ends at the edge and the app listens on plain HTTP, so the connection
  itself says `http`. Anything built from the request URL (the API's
  `links.next`, say) would hand clients an `http://` address to send their
  Bearer key to. The configured URL is the only input: no request header
  (`x-forwarded-proto` and friends) is read, so a client cannot choose it.

  When the configured scheme is not `https` (dev, test) the conn is left
  alone. Pass `url: [...]` to override the endpoint's `:url` config.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    url = Keyword.get_lazy(opts, :url, &configured_url/0)

    case Keyword.get(url, :scheme) do
      "https" ->
        %{conn | scheme: :https, host: url[:host] || conn.host, port: url[:port] || 443}

      _ ->
        conn
    end
  end

  defp configured_url do
    :wallop_web
    |> Application.get_env(WallopWeb.Endpoint, [])
    |> Keyword.get(:url, [])
  end
end
