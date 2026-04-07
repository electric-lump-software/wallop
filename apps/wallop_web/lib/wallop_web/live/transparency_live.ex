defmodule WallopWeb.TransparencyLive do
  @moduledoc """
  Public transparency log: lists every Merkle root anchor produced by the
  daily transparency worker, with the drand round number that pins each one
  to an external timestamp.
  """
  use WallopWeb, :live_view

  require Ash.Query

  alias WallopCore.Resources.TransparencyAnchor

  @impl true
  def mount(_params, _session, socket) do
    anchors =
      TransparencyAnchor
      |> Ash.Query.sort(anchored_at: :desc)
      |> Ash.Query.limit(200)
      |> Ash.read!(authorize?: false)

    {:ok,
     socket
     |> assign(anchors: anchors, page_title: "Transparency log — Wallop"), layout: false}
  end

  def hex(nil), do: ""
  def hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
end
