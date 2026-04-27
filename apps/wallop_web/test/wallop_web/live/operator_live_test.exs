defmodule WallopWeb.OperatorLiveTest do
  use WallopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WallopCore.TestHelpers

  alias WallopCore.Resources.Draw

  describe "operator listing — cross-draw transparency commitment" do
    test "lists draws with assigned operator_sequence", %{conn: conn} do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      locked = create_draw(api_key)

      assert is_integer(locked.operator_sequence),
             "create_draw helper must produce a locked draw with an assigned sequence"

      {:ok, _live, html} = live(conn, "/operator/#{operator.slug}")

      assert html =~ "##{locked.operator_sequence}",
             "locked draw with sequence ##{locked.operator_sequence} must appear in the listing"
    end

    test "does NOT list a draw in :open status (operator working state)", %{conn: conn} do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      locked = create_draw(api_key)

      {:ok, open_draw} =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 2}, actor: api_key)
        |> Ash.create()

      # Sanity: both draws have a sequence (assigned at create), but only
      # the helper-produced one has been locked and transitioned out of :open.
      assert is_integer(locked.operator_sequence)
      assert is_integer(open_draw.operator_sequence)
      assert open_draw.status == :open
      assert locked.status != :open

      {:ok, _live, html} = live(conn, "/operator/#{operator.slug}")

      assert html =~ "##{locked.operator_sequence}",
             "locked draw must appear"

      refute html =~ open_draw.id,
             ":open draw (operator working state) must NOT appear in the listing"
    end

    test "PubSub realtime update is ignored for :open draws", %{conn: conn} do
      operator = create_operator()
      api_key = create_api_key_for_operator(operator)
      _locked = create_draw(api_key)

      {:ok, live, _html} = live(conn, "/operator/#{operator.slug}")

      {:ok, open_draw} =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 2}, actor: api_key)
        |> Ash.create()

      assert open_draw.status == :open

      send(live.pid, {:draw_updated, open_draw})

      # Allow the LiveView process to handle the message.
      _ = :sys.get_state(live.pid)

      html = render(live)

      refute html =~ open_draw.id,
             "PubSub broadcast of an :open draw must NOT add it to the listing"
    end
  end
end
