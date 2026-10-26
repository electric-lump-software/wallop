defmodule WallopCore.Resources.OperatorDrawProtocolTest do
  use WallopCore.DataCase, async: false
  import WallopCore.TestHelpers
  require Ash.Query
  alias Ash.Resource.Info
  alias WallopCore.Resources.Operator

  test "new operators are on the observation protocol" do
    assert create_operator().draw_protocol == :observation
  end

  test "an operator row written without a protocol gets observation from the database" do
    id = Ecto.UUID.generate()

    WallopCore.Repo.query!(
      "INSERT INTO operators (id, slug, name, inserted_at, updated_at) VALUES ($1, $2, $3, now(), now())",
      [Ecto.UUID.dump!(id), "op-default-#{System.unique_integer([:positive])}", "Default"]
    )

    assert Ash.get!(Operator, id, authorize?: false).draw_protocol == :observation
  end

  test "the database refuses the retired forecast protocol, by insert or update" do
    op = create_operator()

    assert db_refused?("UPDATE operators SET draw_protocol = 'forecast' WHERE id = $1", [
             Ecto.UUID.dump!(op.id)
           ])

    assert db_refused?(
             "INSERT INTO operators (id, slug, name, draw_protocol, inserted_at, updated_at) VALUES ($1, $2, $3, 'forecast', now(), now())",
             [
               Ecto.UUID.dump!(Ecto.UUID.generate()),
               "op-forecast-#{System.unique_integer([:positive])}",
               "Forecast"
             ]
           )

    assert Ash.get!(Operator, op.id, authorize?: false).draw_protocol == :observation
  end

  test "the admin action switches the protocol and is audited" do
    op = create_operator()

    {:ok, op} =
      op
      |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :frequency})
      |> Ash.update(authorize?: false)

    assert op.draw_protocol == :frequency

    versions =
      Operator.Version
      |> Ash.Query.filter(version_source_id == ^op.id)
      |> Ash.read!(authorize?: false)

    assert Enum.any?(versions, &(&1.version_action_name == :set_draw_protocol))
  end

  test "no actor can switch it, including the operator's own key" do
    op = create_operator()
    key = create_api_key_for_operator(op)

    assert {:error, %Ash.Error.Forbidden{}} =
             op
             |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :observation},
               actor: key
             )
             |> Ash.update()

    assert {:error, %Ash.Error.Forbidden{}} =
             op
             |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :observation},
               actor: nil
             )
             |> Ash.update()
  end

  test "observation and frequency are accepted; nothing else" do
    for ok <- [:observation, :frequency] do
      assert {:ok, %{draw_protocol: ^ok}} =
               create_operator()
               |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: ok})
               |> Ash.update(authorize?: false)
    end

    for bad <- [:forecast, :v6, :v5, :freq, :drand, :other] do
      assert {:error, %Ash.Error.Invalid{}} =
               create_operator()
               |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: bad})
               |> Ash.update(authorize?: false)
    end
  end

  test "no actor can switch an operator to frequency, including its own key" do
    op = create_operator()
    key = create_api_key_for_operator(op)

    for actor <- [key, nil] do
      assert {:error, %Ash.Error.Forbidden{}} =
               op
               |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :frequency},
                 actor: actor
               )
               |> Ash.update()
    end

    assert Ash.get!(Operator, op.id, authorize?: false).draw_protocol == :observation
  end

  test "create_freq_operator/0 gives a frequency operator and its key" do
    {op, key} = create_freq_operator()
    assert op.draw_protocol == :frequency
    assert key.operator_id == op.id
  end

  test "the flag is not exposed through public attributes" do
    refute :draw_protocol in Enum.map(Info.public_attributes(Operator), & &1.name)
  end
end
