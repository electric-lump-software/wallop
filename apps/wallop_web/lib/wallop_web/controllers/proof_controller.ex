defmodule WallopWeb.ProofController do
  @moduledoc """
  Serves proof pages. Terminal draws (completed/failed/expired) are rendered
  as static HTML with CDN cache headers. In-progress draws redirect to the
  LiveView for real-time updates.
  """
  use WallopWeb, :controller

  require Ash.Query

  alias WallopCore.Proof

  @terminal_statuses [:completed, :failed, :expired]
  @default_entries_limit 100
  @max_entries_limit 1000
  # Statuses where entry list is frozen and safe to expose publicly.
  # `:open` is deliberately excluded — pre-lock, entries can still be added
  # or removed and real-time scraping would leak competitive information
  # to observers (weight distribution, count trends) before lock.
  @locked_or_terminal_statuses [
    :locked,
    :awaiting_entropy,
    :pending_entropy,
    :completed,
    :failed,
    :expired
  ]
  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  def show(conn, params) do
    id = params["id"]
    entry_id = params["entry_id"]

    case load_draw(id) do
      {:ok, draw} ->
        if draw.status in @terminal_statuses do
          render_static(conn, draw, entry_id)
        else
          redirect_to_live(conn, id, entry_id)
        end

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Draw not found")
        |> redirect(to: ~p"/")
    end
  end

  defp render_static(conn, draw, entry_id) do
    check_result = if entry_id, do: check_entry(draw, entry_id)
    entries = WallopCore.Entries.load_for_draw(draw.id)
    {operator, receipt, execution_receipt} = WallopCore.OperatorInfo.for_draw(draw)

    {operator_public_key_hex, infra_public_key_hex} =
      WallopCore.OperatorInfo.signing_keys_hex(receipt, execution_receipt)

    conn
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> put_layout(html: {WallopWeb.Layouts, :app})
    |> assign(:page_title, "Draw Proof")
    |> render(:show,
      draw: draw,
      check_result: check_result,
      checked_entry_id: entry_id,
      entries_json: entries_to_json(entries),
      results_json: results_to_json(draw.results),
      operator: operator,
      receipt: receipt,
      execution_receipt: execution_receipt,
      operator_public_key_hex: operator_public_key_hex,
      infra_public_key_hex: infra_public_key_hex
    )
  end

  defp entries_to_json(entries) do
    entries
    |> Enum.map(fn %{uuid: uuid, weight: weight} ->
      %{"uuid" => uuid, "weight" => weight}
    end)
    |> Jason.encode!()
  end

  defp results_to_json(nil), do: "[]"

  defp results_to_json(results) do
    Jason.encode!(results)
  end

  defp redirect_to_live(conn, id, nil) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> redirect(to: ~p"/live/proof/#{id}")
  end

  defp redirect_to_live(conn, id, entry_id) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> redirect(to: ~p"/live/proof/#{id}/#{entry_id}")
  end

  @doc """
  Public paginated entries endpoint.

  `GET /proof/:id/entries?after=<uuid>&limit=<n>` — returns the list of
  entries for a draw as `{uuid, weight}` tuples, sorted ascending by
  `uuid` (binary lex). Keyset paginated: include `?after=<uuid>` to get
  the next page. Response includes `next_after` when more entries
  exist.

  Never includes `operator_ref` — that is operator-private and visible
  only via the authenticated API. This endpoint is the public surface
  a third-party verifier uses to reproduce the committed `entry_hash`.

  Cache headers:
  - Draw is locked (entries immutable): `max-age=31536000, immutable`.
  - Draw is still open: short cache window (`max-age=10`), since
    entries can still be added or removed.
  """
  def entries_index(conn, %{"id" => id} = params) do
    with {:ok, draw} <- load_draw(id),
         :ok <- require_locked_or_terminal(draw),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, after_uuid} <- parse_after(params["after"]) do
      entries = list_entries(draw.id, after_uuid, limit)

      {entries_page, next_after} = split_cursor(entries, limit)
      body = build_body(entries_page, next_after)

      conn
      |> put_entries_cache_headers(draw.status)
      |> json(body)
    else
      {:error, :not_found} -> not_found(conn)
      {:error, :bad_limit} -> bad_request(conn, "limit must be a positive integer")
      {:error, :bad_after} -> bad_request(conn, "after must be a lowercase hyphenated UUID")
    end
  end

  defp require_locked_or_terminal(%{status: status})
       when status in @locked_or_terminal_statuses,
       do: :ok

  # Treat open-draw entry queries as "not found" — the entry list is still
  # in flux and is not yet a fixed public artefact.
  defp require_locked_or_terminal(_), do: {:error, :not_found}

  defp parse_limit(nil), do: {:ok, @default_entries_limit}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, min(n, @max_entries_limit)}
      _ -> {:error, :bad_limit}
    end
  end

  defp parse_limit(_), do: {:error, :bad_limit}

  defp parse_after(nil), do: {:ok, nil}

  defp parse_after(raw) when is_binary(raw) do
    if Regex.match?(@uuid_regex, raw) do
      {:ok, raw}
    else
      {:error, :bad_after}
    end
  end

  defp parse_after(_), do: {:error, :bad_after}

  defp list_entries(draw_id, nil, limit) do
    WallopCore.Resources.Entry
    |> Ash.Query.filter(draw_id == ^draw_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read!(authorize?: false)
  end

  defp list_entries(draw_id, after_uuid, limit) when is_binary(after_uuid) do
    WallopCore.Resources.Entry
    |> Ash.Query.filter(draw_id == ^draw_id and id > ^after_uuid)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read!(authorize?: false)
  end

  defp split_cursor(entries, limit) when length(entries) > limit do
    page = Enum.take(entries, limit)
    {page, List.last(page).id}
  end

  defp split_cursor(entries, _limit), do: {entries, nil}

  defp build_body(entries, nil) do
    %{entries: Enum.map(entries, &serialise_entry/1)}
  end

  defp build_body(entries, next_after) do
    %{
      entries: Enum.map(entries, &serialise_entry/1),
      next_after: next_after
    }
  end

  defp serialise_entry(entry) do
    # uuid + weight ONLY. operator_ref is private and must never appear here.
    %{uuid: entry.id, weight: entry.weight}
  end

  defp put_entries_cache_headers(conn, status) when status in @locked_or_terminal_statuses do
    put_resp_header(conn, "cache-control", "public, max-age=31536000, immutable")
  end

  defp put_entries_cache_headers(conn, _open) do
    put_resp_header(conn, "cache-control", "public, max-age=10")
  end

  defp check_entry(draw, entry_id) do
    {:ok, result} = Proof.check_entry(draw, entry_id)
    result
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

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> json(%{error: "not found"})
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(400)
    |> json(%{error: message})
  end
end
