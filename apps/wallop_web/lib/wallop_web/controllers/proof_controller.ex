defmodule WallopWeb.ProofController do
  @moduledoc """
  Serves proof pages. Terminal draws (completed/failed/expired) are rendered
  as static HTML with CDN cache headers. In-progress draws redirect to the
  LiveView for real-time updates.
  """
  use WallopWeb, :controller

  alias WallopCore.Proof

  @terminal_statuses [:completed, :failed, :expired]

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
    |> Enum.map(fn %{id: id, weight: weight} -> %{"id" => id, "weight" => weight} end)
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
end
