defmodule WallopCore.Entropy.FrequencyDrawExecutionTest do
  @moduledoc """
  Grid-frequency draws run end to end through `ObservationDrawWorker`, on
  real geometry: a draw locked for a round that published about ten
  seconds ago, so F + M has passed and the round is public. The drand stub
  echoes the requested round with quicknet round 33068212's real
  signature, which `WallopCore.Test.DrandBls` accepts at any round; every
  other signature goes to the real BLS check.
  """
  use WallopCore.DataCase, async: false
  use Oban.Testing, repo: WallopCore.Repo

  @moduletag :capture_log

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Entropy.{DrandClient, ObservationDrawWorker, V6Rules}
  alias WallopCore.Frequency.Schedule
  alias WallopCore.ProofBundle
  alias WallopCore.Protocol
  alias WallopCore.Protocol.Tags.Freq
  alias WallopCore.Resources.Draw

  @randomness "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd"
  @signature "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"
  @value "50018;50012;49983;49980;49953;49912;49883;49887"
  @other "50018;50012;49983;49980;49953;49912;49883;49888"

  setup do
    ensure_infrastructure_key()
    test_pid = self()

    Application.put_env(:wallop_core, DrandClient,
      req_options: [plug: {Req.Test, DrandClient}, retry: false]
    )

    Req.Test.stub(DrandClient, fn conn ->
      round = conn.path_info |> List.last() |> String.to_integer()
      send(test_pid, {:drand_fetched, round})

      Req.Test.json(conn, %{
        "round" => round,
        "randomness" => @randomness,
        "signature" => @signature
      })
    end)

    on_exit(fn -> Application.delete_env(:wallop_core, DrandClient) end)
  end

  defp round_at(offset), do: Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), offset))

  defp freq_draw(pub_offset \\ -10) do
    {op, key} = create_freq_operator()
    round = round_at(pub_offset)

    {op,
     put_freq_awaiting!(open_draw_with_entries(key), Schedule.freq_start_for_round(round), round)}
  end

  defp reload(d), do: Ash.get!(Draw, d.id, authorize?: false)

  defp exec_payload(d),
    do:
      Jason.decode!(
        Ash.load!(reload(d), :execution_receipt, authorize?: false).execution_receipt.payload_jcs
      )

  defp with_triggers_off(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("RESET session_replication_role")
    end
  end

  test "a stored window is used: the frequency seed, freq_value signed, every weather field null" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :executed]])
    {_op, draw} = freq_draw()
    put_frequency_window!(draw.freq_start, @value)

    assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
    done = reload(draw)
    assert done.status == :completed
    assert {done.freq_value, done.freq_fallback_reason} == {@value, nil}

    assert {done.weather_value, done.weather_fallback_reason, done.weather_observation_time} ==
             {nil, nil, nil}

    {seed, json} = Protocol.compute_freq_seed(done.entry_hash, @randomness, @value)
    assert done.seed == Base.encode16(seed, case: :lower)
    assert done.seed_json == json

    p = exec_payload(draw)
    assert Enum.sort(Map.keys(p)) == Freq.exec_keys()
    assert {p["schema_version"], p["entropy_composition"]} == {"5", Freq.tag()}
    assert {p["freq_value"], p["freq_fallback_reason"]} == {@value, nil}
    assert p["seed"] == done.seed

    assert Enum.all?(
             ~w(weather_station weather_value weather_observation_time weather_fallback_reason),
             &is_nil(p[&1])
           )

    tag = Freq.tag()

    assert_received {[:wallop_core, :v6, :executed], ^ref, %{count: 1},
                     %{entropy_composition: ^tag, station: nil, fallback?: false}}
  end

  test "nothing stored by F: drand alone, by rule, with no_frequency_by_deadline" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :executed]])
    {_op, draw} = freq_draw()
    assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
    done = reload(draw)
    assert done.status == :completed
    assert {done.freq_value, done.freq_fallback_reason} == {nil, Freq.fallback_reason()}

    {seed, _} = Protocol.compute_seed(done.entry_hash, @randomness)
    assert done.seed == Base.encode16(seed, case: :lower)

    p = exec_payload(draw)
    assert {p["freq_value"], p["freq_fallback_reason"]} == {nil, Freq.fallback_reason()}
    assert p["weather_station"] == nil

    tag = Freq.tag()

    assert_received {[:wallop_core, :v6, :executed], ^ref, %{count: 1},
                     %{entropy_composition: ^tag, station: nil, fallback?: true}}
  end

  test "before pub(R): a snooze, and drand isn't fetched" do
    {_op, draw} = freq_draw(300)
    assert {:snooze, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
    refute_received {:drand_fetched, _}
    assert reload(draw).status == :awaiting_entropy
  end

  test "drand forged by one relay: the next relay is used (BLS checked)" do
    Application.put_env(:wallop_core, DrandClient,
      req_options: [plug: {Req.Test, DrandClient}, retry: false],
      relays: ["https://relay-one.test", "https://relay-two.test"]
    )

    Req.Test.stub(DrandClient, fn conn ->
      round = conn.path_info |> List.last() |> String.to_integer()

      signature =
        if conn.host == "relay-one.test", do: String.duplicate("ab", 48), else: @signature

      randomness =
        :crypto.hash(:sha256, Base.decode16!(signature, case: :lower))
        |> Base.encode16(case: :lower)

      Req.Test.json(conn, %{
        "round" => round,
        "randomness" => randomness,
        "signature" => signature
      })
    end)

    {_op, draw} = freq_draw()
    assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
    done = reload(draw)
    assert done.status == :completed
    assert done.drand_signature == @signature
  end

  test "drand down on the last attempt: {:error, _}, drand_exhausted, never failed or cancelled" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:wallop_core, :v6, :drand_exhausted],
        [:wallop_core, :v6, :exec_refused]
      ])

    Req.Test.stub(DrandClient, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    {_op, draw} = freq_draw()

    assert {:error, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id}, attempt: 10)
    assert reload(draw).status in [:awaiting_entropy, :pending_entropy]
    assert_received {[:wallop_core, :v6, :drand_exhausted], ^ref, _, %{draw_id: _}}
    refute_received {[:wallop_core, :v6, :exec_refused], ^ref, _, _}
  end

  test "stored state no retry can change (an entry hash mismatch) is refused and cancelled, not failed" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:wallop_core, :v6, :exec_refused]])
    {_op, draw} = freq_draw()

    with_triggers_off(fn ->
      Repo.query!("UPDATE draws SET entry_hash = $2 WHERE id = $1", [
        Ecto.UUID.dump!(draw.id),
        String.duplicate("0", 64)
      ])
    end)

    assert {:cancel, _} = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
    assert reload(draw).status in [:awaiting_entropy, :pending_entropy]
    assert_received {[:wallop_core, :v6, :exec_refused], ^ref, _, %{draw_id: _}}
  end

  test "the signer's re-check: a freq_value that isn't T's stored window is refused" do
    {_op, draw} = freq_draw()
    put_frequency_window!(draw.freq_start, @value)

    with_triggers_off(fn ->
      Repo.query!("UPDATE draws SET freq_value = $2 WHERE id = $1", [
        Ecto.UUID.dump!(draw.id),
        @other
      ])
    end)

    assert V6Rules.receipt_input(:freq, reload(draw)) ==
             {:error, "the draw's freq_value is not the stored window for its start"}
  end

  test "the operator's flag is never read: a draw locked as frequency runs as frequency" do
    {op, draw} = freq_draw()

    {:ok, _} =
      op
      |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :observation})
      |> Ash.update(authorize?: false)

    assert :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})
    done = reload(draw)
    assert done.status == :completed
    assert done.freq_fallback_reason == Freq.fallback_reason()
    assert done.weather_fallback_reason == nil
  end

  test "the proof bundle carries freq_value in entropy, and no weather_value" do
    {_op, draw} = freq_draw()
    put_frequency_window!(draw.freq_start, @value)
    :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})

    {:ok, bundle} = ProofBundle.build(reload(draw))
    entropy = Jason.decode!(bundle)["entropy"]
    assert entropy["freq_value"] == @value
    refute Map.has_key?(entropy, "weather_value")
  end

  test "the bundle chooses its value by tag: a weather_value on a frequency draw is never served" do
    {_op, draw} = freq_draw()
    :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})

    with_triggers_off(fn ->
      Repo.query!("UPDATE draws SET weather_value = '141;1025;85;2432' WHERE id = $1", [
        Ecto.UUID.dump!(draw.id)
      ])
    end)

    {:ok, bundle} = ProofBundle.build(reload(draw))
    refute Map.has_key?(Jason.decode!(bundle)["entropy"], "weather_value")
  end

  test "a fallback's proof bundle carries neither value" do
    {_op, draw} = freq_draw()
    :ok = perform_job(ObservationDrawWorker, %{draw_id: draw.id})

    {:ok, bundle} = ProofBundle.build(reload(draw))
    entropy = Jason.decode!(bundle)["entropy"]
    refute Map.has_key?(entropy, "freq_value")
    refute Map.has_key?(entropy, "weather_value")
    assert entropy["drand_randomness"] == @randomness
  end
end
