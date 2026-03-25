defmodule WallopWeb.ProofLive do
  @moduledoc """
  Public proof page for a draw.

  Displays real-time progress during a live draw and permanent
  verification records for completed draws.
  """
  use WallopWeb, :live_view

  import WallopWeb.Components.DrawTimeline
  import WallopWeb.Components.ProofChain
  import WallopWeb.Components.WinnerList
  import WallopWeb.Components.EntryCheck

  alias WallopCore.Proof

  def mount(%{"id" => id}, _session, socket) do
    case load_draw(id) do
      {:ok, draw} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(WallopWeb.PubSub, "draw:#{id}")
        end

        {:ok,
         assign(socket,
           draw: draw,
           draw_id: id,
           check_result: nil,
           verify_result: nil,
           page_title: "Draw Proof"
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Draw not found")
         |> redirect(to: "/")}
    end
  end

  def handle_info({:draw_updated, draw}, socket) do
    if draw.id == socket.assigns.draw_id do
      {:noreply, assign(socket, :draw, draw)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("check_entry", %{"entry_id" => entry_id}, socket) do
    {:ok, result} = Proof.check_entry(socket.assigns.draw, entry_id)
    {:noreply, assign(socket, :check_result, result)}
  end

  def handle_event("re_verify", _params, socket) do
    result = Proof.verify(socket.assigns.draw)
    {:noreply, assign(socket, :verify_result, result)}
  end

  defp load_draw(id) do
    case Ash.get(WallopCore.Resources.Draw, id,
           domain: WallopCore.Domain,
           authorize?: false
         ) do
      {:ok, draw} -> {:ok, draw}
      _ -> {:error, :not_found}
    end
  end
end
