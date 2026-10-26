defmodule WallopCore.Attacks.DrandRelayTest do
  @moduledoc """
  A single hostile or broken drand relay, always tried first, must neither
  stall an observation-weather draw after pub(R) nor put its own bytes into
  what is stored.

  `V6Execution` fetches with `on_invalid: :next`: one relay's bad answer
  (a body that isn't a JSON object, a 404, a 401 or 403) moves on to the
  next relay. Each relay gets a total deadline and no Req retries, so a
  relay that drips bytes or asks for a long `Retry-After` is abandoned.
  Every body is read through a 16 KiB cap, and the stored `drand_response`
  is the beacon re-encoded, never the relay's bytes. A fetch or skew check
  that exits never crashes the job.
  """
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{DrandClient, ObservationDrawWorker}
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.Schedule

  @w Schedule.fetch_window_seconds()
  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @signature "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"
  @first_relay "api.drand.sh"

  setup do
    ensure_infrastructure_key()

    Application.put_env(:wallop_core, DrandClient,
      req_options: [plug: {Req.Test, DrandClient}, retry: false]
    )

    on_exit(fn -> Application.delete_env(:wallop_core, DrandClient) end)
  end

  # The first relay answers with `hostile`; every other relay is honest.
  defp first_relay_hostile(hostile) do
    Req.Test.stub(DrandClient, fn conn ->
      if conn.host == @first_relay do
        hostile.(conn)
      else
        round = conn.path_info |> List.last() |> String.to_integer()

        Req.Test.json(conn, %{
          "round" => round,
          "randomness" => @randomness,
          "signature" => @signature
        })
      end
    end)
  end

  defp v6_draw_ready do
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(-(@w + 60)) |> DateTime.truncate(:second)
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))
    put_v6_awaiting!(open_draw_with_entries(key), wt, round)
  end

  defp reload(d), do: Ash.get!(Draw, d.id, authorize?: false)

  describe "one bad relay does not stall a v6 draw when the others have the round" do
    # A 200 whose body is a JSON array, null, or a non-JSON page is a
    # malformed body, never a crash, so the next relay is tried.
    for {label, respond} <- [
          {"a JSON array", quote(do: fn conn -> Req.Test.json(conn, []) end)},
          {"JSON null", quote(do: fn conn -> Req.Test.json(conn, nil) end)},
          {"an HTML page",
           quote(
             do: fn conn ->
               conn
               |> Plug.Conn.put_resp_content_type("text/html")
               |> Plug.Conn.send_resp(200, "<html>captive portal</html>")
             end
           )}
        ] do
      test "a 200 with #{label} from the first relay" do
        draw = v6_draw_ready()
        first_relay_hostile(unquote(respond))

        assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
        assert reload(draw).status == :completed
      end
    end

    # A 404 after pub(R) is a lie or a lagging relay: ask the next one.
    test "a 404 from the first relay after pub(R)" do
      draw = v6_draw_ready()
      first_relay_hostile(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :completed
    end

    # The public relays take no credentials, so one relay's 401/403 says
    # nothing about the others.
    test "a 403 from the first relay" do
      draw = v6_draw_ready()
      first_relay_hostile(fn conn -> Plug.Conn.send_resp(conn, 403, "") end)

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :completed
    end
  end

  describe "every relay sending a malformed body" do
    test "is transient: retried, and the last attempt is an error reported as exhausted, never cancelled or failed" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:wallop_core, :v6, :exec_refused],
          [:wallop_core, :v6, :drand_exhausted]
        ])

      draw = v6_draw_ready()
      Req.Test.stub(DrandClient, &Req.Test.json(&1, []))

      assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :pending_entropy
      refute_received {[:wallop_core, :v6, :exec_refused], ^ref, _, _}

      assert {:error, reason} =
               perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)

      assert reason =~ "drand unavailable after 10 attempts (all relays failed)"
      assert reload(draw).status == :pending_entropy
      assert_receive {[:wallop_core, :v6, :drand_exhausted], ^ref, _, _}
      refute_received {[:wallop_core, :v6, :exec_refused], ^ref, _, _}
    end
  end

  describe "a fetch that raises" do
    test "is a transient drand failure: retried, the last attempt an error, never a crash or a cancel" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:wallop_core, :v6, :exec_refused],
          [:wallop_core, :v6, :drand_exhausted]
        ])

      draw = v6_draw_ready()
      Req.Test.stub(DrandClient, fn _conn -> raise "relay plug blew up" end)

      assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :pending_entropy

      assert {:error, reason} =
               perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)

      assert reason =~ "drand unavailable after 10 attempts (fetch raised RuntimeError)"
      assert reload(draw).status == :pending_entropy
      assert_receive {[:wallop_core, :v6, :drand_exhausted], ^ref, _, _}
      refute_received {[:wallop_core, :v6, :exec_refused], ^ref, _, _}
    end
  end

  describe "relay-controlled bytes are not stored" do
    test "a body over the cap is refused, and the next relay answers" do
      first_relay_hostile(fn conn ->
        round = conn.path_info |> List.last() |> String.to_integer()

        Req.Test.json(conn, %{
          "round" => round,
          "randomness" => @randomness,
          "signature" => @signature,
          "note" => "this proof was brought to you by a hostile relay",
          "pad" => String.duplicate("0", 2_000_000)
        })
      end)

      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))

      assert {:ok, %{response: response}} =
               DrandClient.fetch_with_failover(Quicknet.chain_hash(), round, on_invalid: :next)

      refute response =~ "hostile relay"

      # The relay that padded its body is refused, v5 or v6.
      assert {:error, :malformed_body} =
               DrandClient.fetch(Quicknet.chain_hash(), round, "https://" <> @first_relay)
    end

    test "the cap is 16 KiB of body" do
      round = 1000

      for {size, expected} <- [
            {DrandClient.max_body_bytes(), :ok},
            {DrandClient.max_body_bytes() + 1, :error}
          ] do
        Req.Test.stub(DrandClient, fn conn ->
          body =
            Jason.encode!(%{
              "round" => round,
              "randomness" => @randomness,
              "signature" => @signature
            })

          padded = body <> String.duplicate(" ", size - byte_size(body))

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, padded)
        end)

        assert elem(DrandClient.fetch(Quicknet.chain_hash(), round), 0) == expected, "#{size}"
      end
    end

    test "a v6 draw stores the beacon re-encoded, not a relay's extra fields" do
      draw = v6_draw_ready()

      first_relay_hostile(fn conn ->
        round = conn.path_info |> List.last() |> String.to_integer()

        Req.Test.json(conn, %{
          "round" => round,
          "randomness" => @randomness,
          "signature" => @signature,
          "note" => "this proof was brought to you by a hostile relay"
        })
      end)

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      done = reload(draw)
      assert done.status == :completed

      assert done.drand_response ==
               ~s({"randomness":"#{@randomness}","round":#{draw.drand_round},"signature":"#{@signature}"})
    end

    test "the client still returns the relay's whole body for v5, under the cap" do
      Req.Test.stub(DrandClient, fn conn ->
        Req.Test.json(conn, %{
          "round" => 1000,
          "randomness" => @randomness,
          "signature" => @signature,
          "previous_signature" => "ab"
        })
      end)

      assert {:ok, %{response: response}} = DrandClient.fetch(Quicknet.chain_hash(), 1000)
      assert Jason.decode!(response)["previous_signature"] == "ab"
    end
  end

  describe "each relay is bounded" do
    defp honest(conn) do
      round = conn.path_info |> List.last() |> String.to_integer()

      Req.Test.json(conn, %{
        "round" => round,
        "randomness" => @randomness,
        "signature" => @signature
      })
    end

    defp put_config(extra) do
      Application.put_env(
        :wallop_core,
        DrandClient,
        Keyword.merge([req_options: [plug: {Req.Test, DrandClient}, retry: false]], extra)
      )
    end

    defp elapsed_ms(fun) do
      {us, result} = :timer.tc(fun)
      {div(us, 1000), result}
    end

    test "a relay that drips bytes slower than the deadline is abandoned for the next" do
      put_config(relay_deadline_ms: 300)

      first_relay_hostile(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(1..10, conn, fn _, conn ->
          Process.sleep(100)
          {:ok, conn} = Plug.Conn.chunk(conn, " ")
          conn
        end)
      end)

      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))

      {ms, result} =
        elapsed_ms(fn ->
          DrandClient.fetch_with_failover(Quicknet.chain_hash(), round, on_invalid: :next)
        end)

      assert {:ok, %{round: ^round}} = result
      assert ms < 900, "took #{ms} ms"
    end

    test "a 503 with Retry-After: 30 moves straight on, with no sleep" do
      # Req's own retries left on in config, as they are outside tests:
      # the bounded fetch turns them off for each relay.
      put_config(req_options: [plug: {Req.Test, DrandClient}])

      first_relay_hostile(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(503, "")
      end)

      round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), -10))

      {ms, result} =
        elapsed_ms(fn ->
          DrandClient.fetch_with_failover(Quicknet.chain_hash(), round, on_invalid: :next)
        end)

      assert {:ok, %{round: ^round}} = result
      assert ms < 2_000, "took #{ms} ms"
    end

    test "every relay hanging ends the attempt within the relay deadlines" do
      put_config(relay_deadline_ms: 200)
      draw = v6_draw_ready()

      Req.Test.stub(DrandClient, fn conn ->
        Process.sleep(5_000)
        honest(conn)
      end)

      {ms, result} =
        elapsed_ms(fn ->
          perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
        end)

      assert {:error, _} = result
      assert reload(draw).status == :pending_entropy
      assert ms < 2_000, "took #{ms} ms"
    end

    test "the worst case attempt fits well inside the job timeout" do
      # Every relay at its full deadline, plus the skew check's cap.
      worst = length(DrandClient.relays()) * DrandClient.relay_deadline_ms() + 3_000
      job_timeout = ObservationDrawWorker.timeout(%Oban.Job{})

      assert DrandClient.relay_deadline_ms() == 10_000
      assert worst * 2 <= job_timeout, "#{worst} ms of #{job_timeout} ms"
    end
  end

  describe "exits" do
    test "a fetch that exits is a transient drand failure: retried, the last attempt an error, never a cancel" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:wallop_core, :v6, :exec_refused],
          [:wallop_core, :v6, :drand_exhausted]
        ])

      draw = v6_draw_ready()
      Req.Test.stub(DrandClient, fn _conn -> exit(:relay_gone) end)

      assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :pending_entropy

      assert {:error, reason} =
               perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)

      assert reason =~ "drand unavailable after 10 attempts (fetch_exited)"
      assert reload(draw).status == :pending_entropy
      assert_receive {[:wallop_core, :v6, :drand_exhausted], ^ref, _, _}
      refute_received {[:wallop_core, :v6, :exec_refused], ^ref, _, _}
    end

    test "a skew check that exits is ignored, and the draw completes" do
      draw = v6_draw_ready()

      Req.Test.stub(DrandClient, fn conn ->
        if List.last(conn.path_info) == "latest", do: exit(:relay_gone), else: honest(conn)
      end)

      assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 1)
      assert reload(draw).status == :completed
    end
  end
end
