defmodule WallopCore.Resources.Draw.ExecuteV6Test do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias Ash.Resource.Info
  alias WallopCore.Drand.Quicknet
  alias WallopCore.Errors.{V6ExecRefused, V6NotYet}
  alias WallopCore.Resources.Draw
  alias WallopCore.Weather.{Observations, Schedule, Stations}

  @w Schedule.fetch_window_seconds()
  @value "141;1025;85;2432"
  @args %{
    drand_randomness: "140117383b03a0c0c7a899a32b8cbd2ffff9e2569504037c358ee8c7c2efe2fd",
    drand_signature:
      "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf",
    drand_response: "{}"
  }

  defp round_at(offset), do: Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), offset))

  defp pending_v6(wt_offset, pub_offset) do
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(wt_offset) |> DateTime.truncate(:second)
    draw = put_v6_awaiting!(open_draw_with_entries(key), wt, round_at(pub_offset))

    draw
    |> Ash.Changeset.for_update(:transition_to_pending, %{})
    |> Ash.update!(authorize?: false)
  end

  defp execute(draw, args \\ @args),
    do: draw |> Ash.Changeset.for_update(:execute_v6, args) |> Ash.update(authorize?: false)

  defp has_error?(%{errors: errors}, module),
    do: Enum.any?(errors, &match?(%{__struct__: ^module}, &1))

  setup do
    ensure_infrastructure_key()
    :ok
  end

  test "is forbidden to actors" do
    {_op, key} = create_v6_operator()
    draw = open_draw_with_entries(key)

    assert {:error, %Ash.Error.Forbidden{}} =
             draw |> Ash.Changeset.for_update(:execute_v6, @args, actor: key) |> Ash.update()
  end

  test "takes no weather argument, and refuses while the window is open" do
    pending = pending_v6(-5 * 60, -10)

    {:ok, _} =
      Observations.store(Stations.primary().id, %{
        value: @value,
        raw: "[]",
        observation_time: pending.weather_time
      })

    assert {:error, error} = execute(pending)
    assert has_error?(error, V6NotYet)
    assert Exception.message(error) =~ "the observation fetch window is still open"

    arguments = Info.action(Draw, :execute_v6).arguments

    assert Enum.map(arguments, & &1.name) == [
             :drand_randomness,
             :drand_signature,
             :drand_response
           ]

    assert Ash.get!(Draw, pending.id, authorize?: false).status == :pending_entropy
  end

  test "refuses before pub(R) even when F has passed" do
    pending = pending_v6(-(@w + 60), 600)
    assert {:error, error} = execute(pending)
    assert has_error?(error, V6NotYet)
    assert Exception.message(error) =~ "the drand round has not published yet"
    assert Ash.get!(Draw, pending.id, authorize?: false).status == :pending_entropy
  end

  test "refuses drand randomness that isn't 64 lowercase hex" do
    pending = pending_v6(-(@w + 60), -10)
    assert {:error, _} = execute(pending, %{@args | drand_randomness: String.duplicate("A", 64)})
  end

  test "can't execute a retired forecast draw" do
    pending = put_retired_forecast_draw!(create_api_key(), :pending_entropy)

    assert {:error, _} = execute(pending)
    assert Ash.get!(Draw, pending.id, authorize?: false).status == :pending_entropy
  end

  test "a stored unknown tag is refused with V6ExecRefused, before anything is read" do
    pending = pending_v6(-(@w + 60), -10)
    other = "drand-quicknet+metoffice-landobs-v2"

    Repo.query!("SET session_replication_role = replica")

    Repo.query!("UPDATE draws SET entropy_composition = $2 WHERE id = $1", [
      Ecto.UUID.dump!(pending.id),
      other
    ])

    Repo.query!("RESET session_replication_role")

    assert {:error, error} = execute(Ash.get!(Draw, pending.id, authorize?: false))
    assert has_error?(error, V6ExecRefused)

    assert Exception.message(error) =~
             "unknown lock_schema_version and entropy_composition pair: (6, #{other})"
  end

  test "executed_at is at or after pub(R), and the receipt carries the draw's tag" do
    pending = pending_v6(-(@w + 60), -10)
    assert {:ok, done} = execute(pending)
    assert DateTime.compare(done.executed_at, Quicknet.pub_time(done.drand_round)) != :lt

    %{execution_receipt: receipt} = Ash.load!(done, :execution_receipt, authorize?: false)
    payload = Jason.decode!(receipt.payload_jcs)
    assert payload["entropy_composition"] == WallopCore.Protocol.landobs_entropy_composition()
    assert payload["drand_round"] == done.drand_round
    assert payload["fair_pick_version"] == to_string(Application.spec(:fair_pick, :vsn))
  end

  test "no reading by F: the round's stored grid-frequency window feeds the seed" do
    freq = "50012;50018;50012;49983;49980;49953;49912;49883"
    pending = pending_v6(-(@w + 60), -10)
    put_frequency_window!(pending.freq_start, freq)
    assert {:ok, done} = execute(pending)

    assert {done.weather_value, done.weather_fallback_reason} ==
             {nil, "no_observation_by_deadline"}

    assert {done.freq_value, done.freq_fallback_reason} == {freq, nil}

    {seed, _} =
      WallopCore.Protocol.compute_freq_seed(done.entry_hash, @args.drand_randomness, freq)

    assert done.seed == Base.encode16(seed, case: :lower)

    %{execution_receipt: receipt} = Ash.load!(done, :execution_receipt, authorize?: false)
    payload = Jason.decode!(receipt.payload_jcs)
    assert {payload["freq_value"], payload["freq_fallback_reason"]} == {freq, nil}
  end

  describe "entry hash" do
    test "entries that still hash to entry_hash execute" do
      pending = pending_v6(-(@w + 60), -10)
      assert {:ok, done} = execute(pending)
      assert done.status == :completed
      assert done.entry_hash == pending.entry_hash
    end

    test "a mismatch is refused with V6ExecRefused, so it is never retried" do
      pending = pending_v6(-(@w + 60), -10)

      Repo.query!("SET session_replication_role = replica")

      Repo.query!("UPDATE draws SET entry_hash = $2 WHERE id = $1", [
        Ecto.UUID.dump!(pending.id),
        String.duplicate("0", 64)
      ])

      Repo.query!("RESET session_replication_role")

      assert {:error, error} = execute(Ash.get!(Draw, pending.id, authorize?: false))
      assert has_error?(error, V6ExecRefused)
      assert Exception.message(error) =~ "entry hash mismatch"
      assert Ash.get!(Draw, pending.id, authorize?: false).status == :pending_entropy
    end
  end
end
