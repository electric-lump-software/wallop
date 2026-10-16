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
    drand_randomness: String.duplicate("a", 64),
    drand_signature: "sig",
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

  test "the forecast execute actions can't complete a v6 draw" do
    pending = pending_v6(-(@w + 60), -10)

    for {action, args} <- [
          {:execute_drand_only, Map.put(@args, :weather_fallback_reason, "weather_unavailable")},
          {:execute_with_entropy,
           Map.merge(@args, %{
             weather_value: "102500",
             weather_raw: "{}",
             weather_observation_time: pending.weather_time
           })}
        ] do
      assert {:error, _} =
               pending |> Ash.Changeset.for_update(action, args) |> Ash.update(authorize?: false),
             "#{action}"
    end

    assert Ash.get!(Draw, pending.id, authorize?: false).status == :pending_entropy
  end

  test "can't execute a forecast draw" do
    draw = create_draw(create_api_key())

    pending =
      draw
      |> Ash.Changeset.for_update(:transition_to_pending, %{})
      |> Ash.update!(authorize?: false)

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
end
