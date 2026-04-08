defmodule WallopWeb.Plugs.ApiKeyAuth do
  @moduledoc "Bearer token authentication via API key with timing-safe verification."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, raw_key} <- extract_bearer_token(conn),
         {:ok, prefix} <- extract_prefix(raw_key),
         {:ok, api_key} <- find_key_by_prefix(prefix),
         :ok <- verify_key(raw_key, api_key) do
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
      _ -> :error
    end
  end

  defp extract_prefix(raw_key) do
    case raw_key do
      "wallop_" <> rest when byte_size(rest) >= 8 ->
        {:ok, String.slice(rest, 0, 8)}

      _ ->
        Bcrypt.no_user_verify()
        :error
    end
  end

  defp find_key_by_prefix(prefix) do
    # Auth-time lookup runs without an actor (we're determining who the actor
    # IS), so we bypass the read policy. The bcrypt verification below is the
    # actual auth check; this is just a directory lookup.
    case WallopCore.Resources.ApiKey
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter_input(%{key_prefix: prefix, active: true})
         |> Ash.read_one(domain: WallopCore.Domain, authorize?: false) do
      {:ok, nil} ->
        Bcrypt.no_user_verify()
        :error

      {:ok, api_key} ->
        {:ok, api_key}

      _ ->
        Bcrypt.no_user_verify()
        :error
    end
  end

  defp verify_key(raw_key, api_key) do
    if Bcrypt.verify_pass(raw_key, api_key.key_hash) do
      :ok
    else
      :error
    end
  end
end
