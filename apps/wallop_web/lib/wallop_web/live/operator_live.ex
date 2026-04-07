defmodule WallopWeb.OperatorLive do
  @moduledoc """
  Public registry page for an operator.

  Lists every draw the operator has ever locked, in sequence order, including
  open, locked, completed, expired, and failed draws. Sequence gaps and
  discarded slots are visible — that is the whole point.

  Server-side keyset paginated on `operator_sequence DESC`. The list grows by
  appending pages as the user scrolls (intersection observer hook), or after
  the user types in the search bar (which resets the stream).
  """
  use WallopWeb, :live_view

  require Ash.Query

  alias WallopCore.Resources.{Draw, Operator}

  @page_size 50

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case load_operator(slug) do
      {:ok, operator} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(WallopCore.PubSub, "operator:#{operator.id}")
        end

        socket =
          socket
          |> assign(operator: operator, page_title: "#{operator.name} — Wallop")
          |> assign_search("")

        {:ok, socket, layout: {WallopWeb.Layouts, :root}}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Operator not found")
         |> redirect(to: "/")}
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign_search(socket, q)}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply, load_next_page(socket)}
  end

  @impl true
  def handle_info({:draw_updated, _draw}, socket) do
    {:noreply, assign_search(socket, socket.assigns.search_query)}
  end

  defp assign_search(socket, q) do
    operator = socket.assigns.operator
    {draws, next_cursor, has_more?} = list_draws(operator.id, q, nil)

    socket
    |> assign(search_query: q, cursor: next_cursor, has_more?: has_more?)
    |> stream(:draws, draws, reset: true)
  end

  defp load_next_page(socket) do
    operator = socket.assigns.operator
    q = socket.assigns.search_query
    {draws, next_cursor, has_more?} = list_draws(operator.id, q, socket.assigns.cursor)

    socket
    |> assign(cursor: next_cursor, has_more?: has_more?)
    |> stream(:draws, draws)
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

  # Returns {draws, next_cursor, has_more?} where next_cursor is the
  # smallest operator_sequence in the page (used as the upper bound for the
  # next page) or nil when no more pages exist.
  defp list_draws(operator_id, query, cursor) do
    base =
      Draw
      |> Ash.Query.filter(operator_id == ^operator_id)
      |> Ash.Query.sort(operator_sequence: :desc)
      |> Ash.Query.limit(@page_size + 1)

    base = if cursor, do: Ash.Query.filter(base, operator_sequence < ^cursor), else: base

    base =
      case String.trim(query || "") do
        "" -> base
        term -> Ash.Query.filter(base, contains(name, ^term))
      end

    rows = Ash.read!(base, authorize?: false)

    case rows do
      [] ->
        {[], nil, false}

      _ when length(rows) > @page_size ->
        page = Enum.take(rows, @page_size)
        last = List.last(page)
        {page, last.operator_sequence, true}

      _ ->
        last = List.last(rows)
        {rows, last.operator_sequence, false}
    end
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
