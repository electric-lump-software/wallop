defmodule WallopWeb.Plugs.PdfExtensionRewrite do
  @moduledoc """
  Rewrites `/proof/<id>.pdf` to `/proof/<id>/pdf` before the router sees
  it.

  Plug's path matcher doesn't allow `:variable.literal` patterns (the
  dot can't follow a path variable), so we can't define `/proof/:id.pdf`
  as a route directly. This plug normalises the path so users can type
  the friendlier `.pdf` extension URL while the router still uses the
  conventional `/pdf` segment internally.

  Bonus: requesting the `.pdf` URL produces a different cache key in
  any upstream CDN than the `/pdf` URL, which is useful when iterating
  on the PDF design and you want to bust intermediary caches without
  purging by hand.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: [proof, id_dot_pdf]} = conn, _opts)
      when proof == "proof" do
    case String.split(id_dot_pdf, ".pdf", parts: 2) do
      [id, ""] when id != "" ->
        %{conn | path_info: ["proof", id, "pdf"], request_path: "/proof/#{id}/pdf"}

      _ ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
