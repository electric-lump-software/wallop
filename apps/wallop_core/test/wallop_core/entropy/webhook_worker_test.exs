defmodule WallopCore.Entropy.WebhookWorkerTest do
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Entropy.WebhookWorker

  setup do
    Application.put_env(:wallop_core, WebhookWorker,
      req_options: [plug: {Req.Test, WebhookWorker}, retry: false]
    )

    on_exit(fn ->
      Application.delete_env(:wallop_core, WebhookWorker)
    end)

    :ok
  end

  describe "perform/1" do
    test "delivers POST with correct payload for completed draw" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{callback_url: "https://example.com/hook", skip_entropy: true})
      draw = execute_draw(draw, test_seed(), api_key)
      assert draw.status == :completed

      test_pid = self()

      Req.Test.stub(WebhookWorker, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:webhook, body, Plug.Conn.get_req_header(conn, "x-wallop-signature")})
        Req.Test.json(conn, %{ok: true})
      end)

      assert :ok =
               WebhookWorker.perform(%Oban.Job{
                 args: %{"draw_id" => draw.id, "api_key_id" => api_key.id}
               })

      assert_receive {:webhook, body, [signature]}
      decoded = Jason.decode!(body)
      assert decoded["draw_id"] == draw.id
      assert decoded["status"] == "completed"
      refute Map.has_key?(decoded, "failure_reason")

      assert String.starts_with?(signature, "t=")
      assert String.contains?(signature, ",v1=")
    end

    test "includes failure_reason for failed draws" do
      api_key = create_api_key()

      draw =
        create_draw(api_key, %{callback_url: "https://example.com/hook", skip_entropy: false})

      assert draw.status == :awaiting_entropy

      # Transition to pending then fail
      draw =
        draw
        |> Ash.Changeset.for_update(:transition_to_pending, %{})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      draw =
        draw
        |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "Weather unavailable"})
        |> Ash.update!(domain: WallopCore.Domain, authorize?: false)

      test_pid = self()

      Req.Test.stub(WebhookWorker, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:webhook, body})
        Req.Test.json(conn, %{ok: true})
      end)

      assert :ok =
               WebhookWorker.perform(%Oban.Job{
                 args: %{"draw_id" => draw.id, "api_key_id" => api_key.id}
               })

      assert_receive {:webhook, body}
      decoded = Jason.decode!(body)
      assert decoded["status"] == "failed"
      assert decoded["failure_reason"] == "Weather unavailable"
    end

    test "HMAC signature can be recomputed" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{callback_url: "https://example.com/hook", skip_entropy: true})
      draw = execute_draw(draw, test_seed(), api_key)

      test_pid = self()

      Req.Test.stub(WebhookWorker, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [sig] = Plug.Conn.get_req_header(conn, "x-wallop-signature")
        send(test_pid, {:webhook, body, sig})
        Req.Test.json(conn, %{ok: true})
      end)

      assert :ok =
               WebhookWorker.perform(%Oban.Job{
                 args: %{"draw_id" => draw.id, "api_key_id" => api_key.id}
               })

      assert_receive {:webhook, body, signature}

      parts = String.split(signature, ",")
      "t=" <> timestamp = Enum.find(parts, &String.starts_with?(&1, "t="))
      "v1=" <> hmac = Enum.find(parts, &String.starts_with?(&1, "v1="))

      message = "#{timestamp}.#{body}"

      expected_hmac =
        :crypto.mac(:hmac, :sha256, api_key.webhook_secret, message)
        |> Base.encode16(case: :lower)

      assert hmac == expected_hmac
    end

    test "returns :ok when no callback_url" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{skip_entropy: true})
      draw = execute_draw(draw, test_seed(), api_key)

      assert :ok =
               WebhookWorker.perform(%Oban.Job{
                 args: %{"draw_id" => draw.id, "api_key_id" => api_key.id}
               })
    end

    test "returns :ok on delivery failure (best effort)" do
      api_key = create_api_key()
      draw = create_draw(api_key, %{callback_url: "https://example.com/hook", skip_entropy: true})
      draw = execute_draw(draw, test_seed(), api_key)

      Req.Test.stub(WebhookWorker, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert :ok =
               WebhookWorker.perform(%Oban.Job{
                 args: %{"draw_id" => draw.id, "api_key_id" => api_key.id}
               })
    end
  end
end
