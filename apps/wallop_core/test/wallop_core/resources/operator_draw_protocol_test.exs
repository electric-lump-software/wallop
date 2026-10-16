defmodule WallopCore.Resources.OperatorDrawProtocolTest do
  use WallopCore.DataCase, async: false
  import WallopCore.TestHelpers
  require Ash.Query
  alias Ash.Resource.Info
  alias WallopCore.Resources.Operator

  test "new operators are on the forecast protocol" do
    assert create_operator().draw_protocol == :forecast
  end

  test "the admin action switches the protocol and is audited" do
    op = create_operator()

    {:ok, op} =
      op
      |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: :observation})
      |> Ash.update(authorize?: false)

    assert op.draw_protocol == :observation

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

  test "forecast, observation and frequency are accepted; nothing else" do
    for ok <- [:forecast, :observation, :frequency] do
      assert {:ok, %{draw_protocol: ^ok}} =
               create_operator()
               |> Ash.Changeset.for_update(:set_draw_protocol, %{draw_protocol: ok})
               |> Ash.update(authorize?: false)
    end

    for bad <- [:v6, :v5, :freq, :drand, :other] do
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

    assert Ash.get!(Operator, op.id, authorize?: false).draw_protocol == :forecast
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
