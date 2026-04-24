defmodule WallopWeb.DrawEntriesController do
  @moduledoc """
  Authenticated, operator-facing endpoints for draw entries.

  Serves two mechanisms the operator needs to work with wallop-assigned
  entry UUIDs:

  - **PATCH /api/v1/draws/:id/entries** (`:create`): append entries, response
    includes `meta.inserted_entries: [{uuid}]` in submission order so the
    caller can map each submitted entry to the wallop-assigned UUID without
    a second round-trip. Transaction-atomic — partial batch failure rolls
    back the whole batch.

  - **GET /api/v1/draws/:id/entries** (`:index`): paginated, keyset-by-UUID,
    returns `{uuid, weight}` sorted ascending. Works at any draw status
    (open, locked, or terminal). Scoped to the owning api_key. At `:locked`
    status onward the response is byte-identical to the public
    `GET /proof/:id/entries`. Used for post-TTL recovery after a network
    drop, and as the canonical source for building the ticket manifest
    Merkle tree at lock time.

  Both routes are placed BEFORE the `AshJsonApiRouter` forward in the
  router so they take precedence over AshJsonApi's generic handlers for
  the same paths.
  """
  use WallopWeb, :controller

  require Ash.Query

  alias WallopCore.Resources.{Draw, Entry}

  @default_limit 100
  @max_limit 1000

  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  # ── PATCH /api/v1/draws/:id/entries ────────────────────────────────

  def create(conn, %{"id" => id} = params) do
    actor = conn.assigns[:api_key]

    with {:ok, entries} <- parse_entries(params),
         {:ok, draw} <- load_draw_owned(id, actor),
         {:ok, updated} <-
           Ash.Changeset.for_update(draw, :add_entries, %{entries: entries}, actor: actor)
           |> Ash.update() do
      inserted_uuids = Ash.Resource.get_metadata(updated, :inserted_entries) || []

      conn
      |> put_status(:ok)
      |> json(build_create_body(updated, inserted_uuids))
    else
      {:error, :bad_entries} ->
        bad_request(conn, "entries must be a list")

      {:error, :not_found} ->
        not_found(conn)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        bad_request(conn, format_errors(errors))

      {:error, %Ash.Error.Forbidden{}} ->
        not_found(conn)

      {:error, other} ->
        # Unexpected internal error — surface as 500, don't masquerade
        # as a client fault.
        internal_error(conn, other)
    end
  end

  # ── GET /api/v1/draws/:id/entries ──────────────────────────────────

  def index(conn, %{"id" => id} = params) do
    actor = conn.assigns[:api_key]

    with {:ok, draw} <- load_draw_owned(id, actor),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, after_uuid} <- parse_after(params["after"]) do
      rows = list_entries(draw.id, after_uuid, limit)
      {page, next_after} = split_cursor(rows, limit)

      conn
      |> json(build_index_body(page, next_after))
    else
      {:error, :not_found} -> not_found(conn)
      {:error, :bad_limit} -> bad_request(conn, "limit must be a positive integer")
      {:error, :bad_after} -> bad_request(conn, "after must be a lowercase hyphenated UUID")
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  # Accept both JSON:API shape (the format AshJsonApi uses and the format
  # existing operators send) and a flat convenience shape.
  defp parse_entries(%{"data" => %{"attributes" => %{"entries" => entries}}})
       when is_list(entries),
       do: {:ok, entries}

  defp parse_entries(%{"entries" => entries}) when is_list(entries), do: {:ok, entries}
  defp parse_entries(_), do: {:error, :bad_entries}

  defp load_draw_owned(_id, nil), do: {:error, :not_found}

  defp load_draw_owned(id, _actor) when not is_binary(id), do: {:error, :not_found}

  defp load_draw_owned(id, actor) do
    if Regex.match?(@uuid_regex, id) do
      case Ash.get(Draw, id, actor: actor) do
        {:ok, draw} -> {:ok, draw}
        _ -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, min(n, @max_limit)}
      _ -> {:error, :bad_limit}
    end
  end

  defp parse_limit(_), do: {:error, :bad_limit}

  defp parse_after(nil), do: {:ok, nil}

  defp parse_after(raw) when is_binary(raw) do
    if Regex.match?(@uuid_regex, raw), do: {:ok, raw}, else: {:error, :bad_after}
  end

  defp parse_after(_), do: {:error, :bad_after}

  # `authorize?: false` is safe here ONLY because `load_draw_owned/2`
  # already ran the Draw `:read` policy (api_key_id == actor.id). The
  # filter `draw_id == ^draw_id` inherits that ownership. Do not hoist
  # these helpers out of this controller without preserving the
  # upstream ownership check.
  defp list_entries(draw_id, nil, limit) do
    Entry
    |> Ash.Query.filter(draw_id == ^draw_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read!(authorize?: false)
  end

  defp list_entries(draw_id, after_uuid, limit) do
    Entry
    |> Ash.Query.filter(draw_id == ^draw_id and id > ^after_uuid)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.read!(authorize?: false)
  end

  defp split_cursor(rows, limit) when length(rows) > limit do
    page = Enum.take(rows, limit)
    {page, List.last(page).id}
  end

  defp split_cursor(rows, _limit), do: {rows, nil}

  defp build_index_body(rows, nil),
    do: %{entries: Enum.map(rows, &%{uuid: &1.id, weight: &1.weight})}

  defp build_index_body(rows, next_after),
    do: %{
      entries: Enum.map(rows, &%{uuid: &1.id, weight: &1.weight}),
      next_after: next_after
    }

  defp build_create_body(draw, inserted_uuids) do
    %{
      data: %{
        id: draw.id,
        type: "draw",
        attributes: %{
          status: draw.status,
          entry_count: draw.entry_count
        }
      },
      meta: %{
        inserted_entries: Enum.map(inserted_uuids, &%{uuid: &1})
      }
    }
  end

  defp format_errors(errors) when is_list(errors) do
    Enum.map_join(errors, "; ", fn
      %{message: m} when is_binary(m) -> m
      other -> inspect(other)
    end)
  end

  defp bad_request(conn, msg) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: [%{detail: msg}]})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: [%{detail: "not found"}]})
  end

  defp internal_error(conn, reason) do
    require Logger
    # Don't inspect raw Ash error structs — they carry UUIDs and field
    # values. Log only the type/class so the failure is debuggable
    # through structured error tracking without bleeding per-draw
    # identifiers into the log stream (spec §4.3).
    Logger.error("DrawEntriesController internal error: #{error_tag(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{errors: [%{detail: "internal error"}]})
  end

  defp error_tag(%module{}), do: inspect(module)
  defp error_tag(reason) when is_atom(reason), do: inspect(reason)
  defp error_tag(_), do: "<unstructured>"
end
