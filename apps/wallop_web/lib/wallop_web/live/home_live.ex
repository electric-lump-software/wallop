defmodule WallopWeb.HomeLive do
  use WallopWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # `layout: false` — HomeLive's template is a full-page layout (its own
    # nav + sections + footer); the root layout already wraps it in
    # `<html>` per the router's `:put_root_layout`. Re-using `:root` as
    # the inner layout here too renders the root template twice and
    # produces the "Cannot bind multiple views to the same DOM element"
    # error LiveSocket throws on connect.
    {:ok,
     socket
     |> assign(active_tab: "plain")
     |> assign(menu_open: false)
     |> assign(waitlist_signed_up: false)
     |> assign(waitlist_error: nil)
     |> assign(page_title: "Provably fair random draws"), layout: false}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket)
      when tab in ["plain", "crypto"] do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("toggle_menu", _params, socket) do
    {:noreply, assign(socket, menu_open: !socket.assigns.menu_open)}
  end

  def handle_event("close_menu", _params, socket) do
    {:noreply, assign(socket, menu_open: false)}
  end

  def handle_event("join_waitlist", %{"email" => email}, socket) do
    email = String.trim(email)

    case Ash.create(WallopCore.Resources.WaitlistSignup, %{email: email}) do
      {:ok, _signup} ->
        {:noreply, assign(socket, waitlist_signed_up: true, waitlist_error: nil)}

      {:error, %Ash.Error.Invalid{} = error} ->
        if has_unique_error?(error) do
          {:noreply, assign(socket, waitlist_signed_up: true, waitlist_error: nil)}
        else
          {:noreply, assign(socket, waitlist_error: "Please enter a valid email address.")}
        end
    end
  end

  defp has_unique_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: :email, message: "has already been taken"} ->
        true

      _ ->
        false
    end)
  end
end
