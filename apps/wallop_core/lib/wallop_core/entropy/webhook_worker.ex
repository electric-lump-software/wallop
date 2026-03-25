defmodule WallopCore.Entropy.WebhookWorker do
  @moduledoc """
  Delivers signed webhook notifications when draws complete or fail.

  Runs on the :webhooks queue (separate from entropy processing).
  Payload is minimal — just draw_id and status. Caller fetches
  full results via GET /api/v1/draws/:id.

  Signature format: X-Wallop-Signature: t=<unix_ts>,v1=<hmac>
  where hmac = HMAC-SHA256(webhook_secret, "<timestamp>.<payload>")
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 1

  require Logger

  @impl true
  def perform(%Oban.Job{args: %{"draw_id" => draw_id, "api_key_id" => api_key_id}}) do
    with {:ok, draw} <- load_draw(draw_id),
         {:ok, api_key} <- load_api_key(api_key_id),
         {:ok, _response} <- deliver(draw, api_key) do
      :ok
    else
      {:error, :no_callback_url} ->
        # Nothing to deliver
        :ok

      {:error, reason} ->
        Logger.warning("Webhook delivery failed for draw #{draw_id}: #{inspect(reason)}")
        # Best-effort: don't retry
        :ok
    end
  end

  defp load_draw(draw_id) do
    case Ash.get(WallopCore.Resources.Draw, draw_id,
           domain: WallopCore.Domain,
           authorize?: false
         ) do
      {:ok, draw} -> {:ok, draw}
      _ -> {:error, :draw_not_found}
    end
  end

  defp load_api_key(api_key_id) do
    case Ash.get(WallopCore.Resources.ApiKey, api_key_id,
           domain: WallopCore.Domain,
           authorize?: false
         ) do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :api_key_not_found}
    end
  end

  defp deliver(draw, api_key) do
    case draw.callback_url do
      nil -> {:error, :no_callback_url}
      url -> post_webhook(url, draw, api_key)
    end
  end

  defp post_webhook(url, draw, api_key) do
    payload = build_payload(draw)
    timestamp = System.system_time(:second)
    signature = compute_signature(payload, timestamp, api_key.webhook_secret)

    headers = [
      {"content-type", "application/json"},
      {"x-wallop-signature", "t=#{timestamp},v1=#{signature}"}
    ]

    case Req.post(
           url,
           [body: payload, headers: headers, receive_timeout: 10_000] ++ req_options()
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, :delivered}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_payload(draw) do
    payload = %{draw_id: draw.id, status: to_string(draw.status)}

    payload =
      if draw.status == :failed and draw.failure_reason do
        Map.put(payload, :failure_reason, draw.failure_reason)
      else
        payload
      end

    Jason.encode!(payload)
  end

  defp compute_signature(payload, timestamp, secret) do
    message = "#{timestamp}.#{payload}"
    :crypto.mac(:hmac, :sha256, secret, message) |> Base.encode16(case: :lower)
  end

  defp req_options do
    Application.get_env(:wallop_core, __MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
