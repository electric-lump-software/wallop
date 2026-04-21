defmodule WallopCore.Entropy.WebhookWorker do
  @moduledoc """
  Delivers signed webhook notifications when draws complete or fail.

  Runs on the :webhooks queue (separate from entropy processing).
  Payload is minimal — just draw_id and status. Caller fetches
  full results via GET /api/v1/draws/:id.

  Retries transient failures (5xx, timeouts) up to 5 attempts with
  exponential backoff. Permanent failures (missing draw, 4xx) are
  cancelled immediately.

  Signature format: X-Wallop-Signature: t=<unix_ts>,v1=<hmac>
  where hmac = HMAC-SHA256(webhook_secret, "<timestamp>.<payload>")
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 5

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def backoff(%Oban.Job{attempt: attempt}) do
    # Exponential backoff: ~30s, ~1m, ~2m, ~4m
    trunc(:math.pow(2, attempt) * 15)
  end

  @impl true
  def perform(%Oban.Job{args: %{"draw_id" => draw_id, "api_key_id" => api_key_id}}) do
    Tracer.with_span "webhook_worker.deliver", attributes: %{"draw.id" => draw_id} do
      with {:ok, draw} <- load_draw(draw_id),
           {:ok, api_key} <- load_api_key(api_key_id),
           {:ok, _response} <- deliver(draw, api_key) do
        Tracer.set_attributes(%{"webhook.status" => "delivered"})
        :ok
      else
        {:error, :no_callback_url} ->
          Tracer.set_attributes(%{"webhook.status" => "skipped"})
          :ok

        {:error, {:transient, reason}} ->
          Tracer.set_attributes(%{
            "error" => true,
            "webhook.status" => "transient_failure",
            "error.message" => inspect(reason)
          })

          Logger.warning(
            "Webhook delivery failed for draw #{draw_id}: #{inspect(reason)}, will retry"
          )

          {:error, reason}

        {:error, reason} ->
          Tracer.set_attributes(%{
            "error" => true,
            "webhook.status" => "permanent_failure",
            "error.message" => inspect(reason)
          })

          Logger.warning("Webhook permanently failed for draw #{draw_id}: #{inspect(reason)}")
          {:cancel, inspect(reason)}
      end
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
    with {:ok, secret} <- decrypt_webhook_secret(api_key.webhook_secret) do
      payload = build_payload(draw)
      timestamp = System.system_time(:second)
      signature = compute_signature(payload, timestamp, secret)

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

        {:ok, %Req.Response{status: status}} when status >= 500 ->
          {:error, {:transient, {:unexpected_status, status}}}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:unexpected_status, status}}

        {:error, %Req.TransportError{} = reason} ->
          {:error, {:transient, reason}}

        {:error, reason} ->
          {:error, {:transient, reason}}
      end
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

  defp decrypt_webhook_secret(encrypted_base64) do
    case encrypted_base64 |> Base.decode64!() |> WallopCore.Vault.decrypt() do
      {:ok, decrypted} ->
        {:ok, decrypted}

      :error ->
        Logger.error(
          "Vault decrypt failed for webhook secret — check VAULT_KEY and iv_length config"
        )

        {:error, :vault_decrypt_failed}
    end
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
