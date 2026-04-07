defmodule WallopWeb.OperatorLive do
  @moduledoc """
  Public registry page for an operator.

  Lists every draw the operator has ever locked, in sequence order, including
  open, locked, completed, expired, and failed draws. Sequence gaps and
  discarded slots are visible — that is the whole point.
  """
  use WallopWeb, :live_view

  require Ash.Query

  alias WallopCore.Resources.{Draw, Operator}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case load_operator(slug) do
      {:ok, operator} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(WallopCore.PubSub, "operator:#{operator.id}")
        end

        draws = list_draws(operator.id)

        {:ok,
         socket
         |> assign(operator: operator, draws: draws, page_title: "#{operator.name} — Wallop"),
         layout: {WallopWeb.Layouts, :root}}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Operator not found")
         |> redirect(to: "/")}
    end
  end

  @impl true
  def handle_info({:draw_updated, _draw}, socket) do
    {:noreply, assign(socket, draws: list_draws(socket.assigns.operator.id))}
  end

  defp load_operator(slug) do
    Operator
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Operator{} = op} -> {:ok, op}
      _ -> :error
    end
  end

  defp list_draws(operator_id) do
    Draw
    |> Ash.Query.filter(operator_id == ^operator_id)
    |> Ash.Query.sort(operator_sequence: :desc)
    |> Ash.Query.limit(500)
    |> Ash.read!(authorize?: false)
  end

  def status_badge_class(:open), do: "badge badge-info"
  def status_badge_class(:locked), do: "badge badge-warning"
  def status_badge_class(:awaiting_entropy), do: "badge badge-warning"
  def status_badge_class(:pending_entropy), do: "badge badge-warning"
  def status_badge_class(:completed), do: "badge badge-success"
  def status_badge_class(:failed), do: "badge badge-error"
  def status_badge_class(:expired), do: "badge badge-ghost"
  def status_badge_class(_), do: "badge"
end
