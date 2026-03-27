defmodule WallopWeb.HomeLive do
  use WallopWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket, layout: {WallopWeb.Layouts, :root}}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-screen">
      <img src={~p"/images/logo.png"} alt="Wallop" class="w-64" />
    </div>
    """
  end
end
