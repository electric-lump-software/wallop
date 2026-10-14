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
  import WallopWeb.Components.OperatorPanel
  import WallopWeb.Components.VerifyBlock
  import WallopWeb.Components.PreLockPanel

  alias WallopCore.Proof
  alias WallopWeb.Plugs.SelfCheckRateLimit
  alias WallopWeb.ProofPreLockView

  @poll_interval_ms 30_000

  @doc """
  Session callback for the router's `live_session`. Runs on the HTTP render,
  where `conn.remote_ip` is the trustworthy client address (the edge guard and
  `RemoteIp` have already run). The value travels in the signed LiveView
  session, so the socket never has to guess it from the proxy's address or a
  client-supplied header. It is stored as the limiter's bucket id, so the live
  page and the HTTP plug count the same client in the same bucket.
  """
  def session(conn) do
    %{"client_ip" => WallopWeb.RateLimiter.ip_bucket(conn.remote_ip)}
  end

  def mount(%{"id" => id} = params, session, socket) do
    entry_id = Map.get(params, "entry_id")

    case load_draw(id) do
      {:ok, draw} when draw.status in [:completed, :failed, :expired] ->
        path = if entry_id, do: ~p"/proof/#{id}/#{entry_id}", else: ~p"/proof/#{id}"
        {:ok, redirect(socket, to: path)}

      {:ok, draw} ->
        peer_ip = Map.get(session, "client_ip", "unknown")

        if connected?(socket) do
          Phoenix.PubSub.subscribe(WallopCore.PubSub, "draw:#{id}")
          schedule_poll_if_live(draw)
        end

        check_result = auto_check_entry(draw, entry_id)
        {operator, receipt, execution_receipt} = WallopCore.OperatorInfo.for_draw(draw)

        {operator_public_key_hex, infra_public_key_hex} =
          WallopCore.OperatorInfo.signing_keys_hex(receipt, execution_receipt)

        {:ok,
         assign(socket,
           draw: draw,
           open_view: open_view_for(draw, operator),
           draw_id: id,
           check_result: check_result,
           checked_entry_id: entry_id,
           peer_ip: peer_ip,
           verify_result: nil,
           revealing: false,
           reveal_from: nil,
           reveal_to: nil,
           entropy_status: nil,
           entries_json: nil,
           results_json: nil,
           operator: operator,
           receipt: receipt,
           execution_receipt: execution_receipt,
           operator_public_key_hex: operator_public_key_hex,
           infra_public_key_hex: infra_public_key_hex,
           verify_command: nil,
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
      schedule_poll_if_live(draw)
      maybe_reveal(%{socket | assigns: Map.put(socket.assigns, :entropy_status, nil)}, draw)
    else
      {:noreply, socket}
    end
  end

  def handle_info({:entropy_status, status}, socket) do
    if socket.assigns.draw.status in [:awaiting_entropy, :pending_entropy] do
      {:noreply, assign(socket, entropy_status: status)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:poll_draw, socket) do
    case load_draw(socket.assigns.draw_id) do
      {:ok, draw} ->
        schedule_poll_if_live(draw)
        maybe_reveal(socket, draw)

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("check_entry", %{"entry_id" => entry_id}, socket) do
    # Mirror the HTTP-side rate limit on the LiveView channel, using the
    # RateLimiter's "self-check" bucket shared with the HTTP plug so budgets
    # unify across transports. Without this, an attacker holding one socket
    # open could fire handle_event faster than the HTTP plug's 60/min would
    # allow.
    case SelfCheckRateLimit.check_rate(socket.assigns.peer_ip) do
      :ok ->
        {:ok, result} = Proof.winner?(socket.assigns.draw, entry_id)
        {:noreply, assign(socket, check_result: result, checked_entry_id: entry_id)}

      :rate_limited ->
        # Say so, rather than render the non-winner copy: a real winner must
        # never be told they lost. Winners are public in `draw.results` and the
        # HTTP path already answers with an explicit 429, so hiding the
        # rate-limit state would protect nothing.
        {:noreply,
         assign(socket,
           check_result: %{rate_limited: true},
           checked_entry_id: entry_id
         )}
    end
  end

  def handle_event("reveal_complete", _params, socket) do
    socket = assign(socket, revealing: false, reveal_from: nil, reveal_to: nil)

    if socket.assigns.draw.status == :completed do
      {:noreply, push_navigate(socket, to: ~p"/proof/#{socket.assigns.draw_id}")}
    else
      {:noreply, socket}
    end
  end

  defp maybe_reveal(socket, draw) do
    old_status = socket.assigns.draw.status
    new_status = draw.status

    cond do
      # Lock transition: open → awaiting_entropy (animate stages 0-3).
      # Refresh the lock receipt — it didn't exist when the LiveView mounted
      # in :open state, but the lock action just wrote it. The reveal_complete
      # redirect masks the user-visible symptom by handing off to the static
      # controller, but this assign refresh keeps the LiveView's internal
      # state consistent — defense in depth for any future code path that
      # renders the receipt panel from the LiveView itself.
      old_status == :open and new_status == :awaiting_entropy ->
        {_operator, lock_receipt, _exec} = WallopCore.OperatorInfo.for_draw(draw)

        {:noreply,
         assign(socket,
           draw: draw,
           open_view: nil,
           receipt: lock_receipt,
           revealing: true,
           reveal_from: 0,
           reveal_to: 3
         )}

      # Completion transition: in-progress → completed (animate stages 4-5).
      # Refresh both receipts — the execution receipt is new, and the lock
      # receipt may also be stale if the user landed on the page after lock
      # but before this branch ever fired (no lock animation, no refresh).
      # Same defense-in-depth rationale as the lock branch above.
      old_status in [:locked, :awaiting_entropy, :pending_entropy] and new_status == :completed ->
        {entries_json, results_json} = load_verify_data(draw)
        {operator, lock_receipt, execution_receipt} = WallopCore.OperatorInfo.for_draw(draw)

        {operator_public_key_hex, infra_public_key_hex} =
          WallopCore.OperatorInfo.signing_keys_hex(lock_receipt, execution_receipt)

        {:noreply,
         assign(socket,
           draw: draw,
           revealing: true,
           reveal_from: 4,
           reveal_to: 5,
           entries_json: entries_json,
           results_json: results_json,
           receipt: lock_receipt,
           execution_receipt: execution_receipt,
           operator_public_key_hex: operator_public_key_hex,
           infra_public_key_hex: infra_public_key_hex,
           verify_command: WallopWeb.VerifyCommand.build(draw.id, operator && operator.slug)
         )}

      true ->
        {:noreply,
         assign(socket,
           draw: draw,
           open_view: open_view_for(draw, socket.assigns[:operator])
         )}
    end
  end

  defp schedule_poll_if_live(%{status: status}) when status in [:completed, :failed], do: :ok

  defp schedule_poll_if_live(_draw) do
    Process.send_after(self(), :poll_draw, @poll_interval_ms)
  end

  defp auto_check_entry(_draw, nil), do: nil

  defp auto_check_entry(draw, entry_id) do
    {:ok, result} = Proof.winner?(draw, entry_id)
    result
  end

  # Build the pre-lock view ONLY for :open status. Any other status
  # gets nil, and the template branches on that. This is the structural
  # firewall — the :open template branch can only render fields the
  # ProofPreLockView struct exposes.
  defp open_view_for(%{status: :open} = draw, operator) do
    ProofPreLockView.from_draw(draw, operator)
  end

  defp open_view_for(_draw, _operator), do: nil

  defp load_verify_data(draw) do
    entries =
      WallopCore.Entries.load_for_draw(draw.id)
      |> Enum.map(fn %{uuid: uuid, weight: weight} -> %{"uuid" => uuid, "weight" => weight} end)

    {Jason.encode!(entries), Jason.encode!(draw.results || [])}
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
