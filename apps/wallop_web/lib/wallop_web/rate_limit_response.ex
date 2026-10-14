defmodule WallopWeb.RateLimitResponse do
  @moduledoc "The one shape of an API 429: `Retry-After` header plus a JSON:API errors array."

  import Plug.Conn

  @spec send_429(Plug.Conn.t(), pos_integer(), String.t(), String.t(), map() | nil) ::
          Plug.Conn.t()
  def send_429(conn, retry_after, code, detail, meta \\ nil) do
    error =
      %{status: "429", code: code, title: "Too many requests", detail: detail}
      |> then(&if(meta, do: Map.put(&1, :meta, meta), else: &1))

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(429)
    |> Phoenix.Controller.json(%{errors: [error]})
    |> halt()
  end
end
