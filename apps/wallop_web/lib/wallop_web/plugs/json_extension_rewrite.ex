defmodule WallopWeb.Plugs.JsonExtensionRewrite do
  @moduledoc """
  Rewrites `/proof/<id>.json` to `/proof/<id>/json` before the router
  sees it.

  Same pattern as `PdfExtensionRewrite` — Plug's path matcher doesn't
  allow `:variable.literal` patterns, so we normalise the friendlier
  `.json` extension URL to a conventional path segment.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [proof, id_dot_json]} = conn, _opts)
      when proof == "proof" do
    case String.split(id_dot_json, ".json", parts: 2) do
      [id, ""] when id != "" ->
        %{conn | path_info: ["proof", id, "json"], request_path: "/proof/#{id}/json"}

      _ ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
