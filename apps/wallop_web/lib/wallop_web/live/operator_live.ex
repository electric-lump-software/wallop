defmodule WallopWeb.OperatorLive do
  @moduledoc """
  Public registry page for an operator.

  Lists every draw the operator has ever locked, in sequence order, including
  open, locked, completed, expired, and failed draws. Sequence gaps and
  discarded slots are visible — that is the whole point.

  Server-side keyset paginated on `operator_sequence DESC`. The list grows by
  appending pages as the user scrolls (intersection observer hook), or after
  the user types in the search bar (which resets the list to page 1).
  """
  use WallopWeb, :live_view

  require Ash.Query

  alias WallopCore.Resources.{Draw, Operator}

  @page_size 50
  @poll_interval_ms 30_000

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case load_operator(slug) do
      {:ok, operator} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(WallopCore.PubSub, "operator:#{operator.id}")
          schedule_poll()
        end

        socket =
          socket
          |> assign(operator: operator, page_title: "#{operator.name} — Wallop")
          |> assign_search("")

        {:ok, socket, layout: false}

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
  def handle_info({:draw_updated, draw}, socket) do
    {:noreply, apply_draw_update(socket, draw)}
  end

  def handle_info(:poll, socket) do
    schedule_poll()
    {:noreply, assign_search(socket, socket.assigns.search_query)}
  end

  # Surgical in-place update of the affected draw in @draws.
  #
  # Phoenix LiveView's change tracking compares assigns with `===`. Ash
  # structs use value-based equality, so re-querying the DB and reassigning
  # the whole list often produces a list that compares equal to the previous
  # one (no diff is pushed even though we just received a broadcast). Update
  # the single affected element directly so the list reference is provably
  # different.
  defp apply_draw_update(socket, %{operator_id: operator_id} = draw)
       when is_binary(operator_id) do
    if operator_id == socket.assigns.operator.id and
         matches_search?(draw, socket.assigns.search_query) do
      draws = upsert_draw(socket.assigns.draws, draw)
      assign(socket, :draws, draws)
    else
      socket
    end
  end

  defp apply_draw_update(socket, _draw), do: socket

  defp upsert_draw(draws, new_draw) do
    case Enum.find_index(draws, &(&1.id == new_draw.id)) do
      nil ->
        [new_draw | draws]
        |> Enum.sort_by(& &1.operator_sequence, :desc)

      idx ->
        List.replace_at(draws, idx, new_draw)
    end
  end

  defp matches_search?(_draw, ""), do: true
  defp matches_search?(_draw, nil), do: true

  defp matches_search?(%{name: nil}, _q), do: false

  defp matches_search?(%{name: name}, q) do
    String.contains?(String.downcase(name), String.downcase(String.trim(q)))
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp assign_search(socket, q) do
    operator = socket.assigns.operator
    {draws, next_cursor, has_more?} = list_draws(operator.id, q, nil)

    assign(socket,
      draws: draws,
      search_query: q,
      cursor: next_cursor,
      has_more?: has_more?
    )
  end

  defp load_next_page(socket) do
    operator = socket.assigns.operator
    q = socket.assigns.search_query
    {more, next_cursor, has_more?} = list_draws(operator.id, q, socket.assigns.cursor)

    assign(socket,
      draws: socket.assigns.draws ++ more,
      cursor: next_cursor,
      has_more?: has_more?
    )
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
        "" ->
          base

        term ->
          like = "%#{term}%"
          Ash.Query.filter(base, fragment("? ILIKE ?", name, ^like))
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
