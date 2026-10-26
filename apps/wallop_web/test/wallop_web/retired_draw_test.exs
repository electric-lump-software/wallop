defmodule WallopWeb.RetiredDrawTest do
  @moduledoc """
  A retired forecast draw (no lock schema, neither open nor expired) is not
  found on every proof route: each answers it exactly as it answers an
  unknown id. Its signed receipts stay served at the
  receipt and execution endpoints. Open and expired draws are not retired.
  """
  use WallopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import WallopCore.TestHelpers

  alias WallopWeb.RetiredDraw

  @unknown "00000000-0000-4000-8000-000000000000"

  defp entry_id(draw), do: hd(WallopCore.Entries.load_for_draw(draw.id)).uuid

  # Everything a client can see of a plain HTTP response, but the flash
  # cookie, which carries a signing time.
  defp seen(conn) do
    %{
      status: conn.status,
      body: conn.resp_body,
      location: get_resp_header(conn, "location"),
      content_type: get_resp_header(conn, "content-type"),
      cache_control: get_resp_header(conn, "cache-control"),
      flash: Phoenix.Flash.get(conn.assigns[:flash] || %{}, :error)
    }
  end

  defp routes(id, entry),
    do: [
      "/proof/#{id}",
      "/proof/#{id}/#{entry}",
      "/proof/#{id}/entries",
      "/proof/#{id}/pdf",
      "/proof/#{id}/json"
    ]

  setup do
    key = create_api_key()

    %{
      key: key,
      retired:
        for(
          status <- [:completed, :failed, :awaiting_entropy, :pending_entropy],
          do: put_retired_forecast_draw!(key, status)
        )
    }
  end

  test "retired?/1: no lock schema and neither open nor expired; needs no query",
       %{key: key, retired: retired} do
    for draw <- retired, do: assert(RetiredDraw.retired?(draw))

    # Exact without a receipt: an old draw locked but never executed.
    for status <- [:locked, :awaiting_entropy, :pending_entropy, :completed, :failed] do
      assert RetiredDraw.retired?(%{lock_schema_version: nil, status: status})
    end

    for status <- [:open, :expired] do
      refute RetiredDraw.retired?(%{lock_schema_version: nil, status: status})
    end

    open = open_draw_with_entries(key)
    refute RetiredDraw.retired?(open)

    expired =
      open
      |> Ash.Changeset.for_update(:expire, %{})
      |> Ash.update!(authorize?: false)

    refute RetiredDraw.retired?(expired)
    refute RetiredDraw.retired?(execute_draw(create_draw(key)))
  end

  test "retired?/1 raises when the fields it reads aren't loaded" do
    not_loaded = %Ash.NotLoaded{field: :lock_schema_version, type: :attribute}

    assert_raise ArgumentError, ~r/needs lock_schema_version and status loaded/, fn ->
      RetiredDraw.retired?(%{lock_schema_version: not_loaded, status: :completed})
    end

    assert_raise ArgumentError, fn -> RetiredDraw.retired?(%{status: :completed}) end
    assert_raise ArgumentError, fn -> RetiredDraw.retired?(%{lock_schema_version: nil}) end
  end

  test "every proof route answers a retired draw exactly as it answers an unknown id",
       %{retired: retired} do
    for draw <- retired do
      entry = entry_id(draw)

      for {retired_path, unknown_path} <-
            Enum.zip(routes(draw.id, entry), routes(@unknown, entry)) do
        retired_seen = seen(get(build_conn(), retired_path))
        unknown_seen = seen(get(build_conn(), unknown_path))

        assert retired_seen == unknown_seen, "#{draw.status} #{retired_path}"
        refute retired_seen.status == 200, retired_path
      end
    end
  end

  test "page, PDF and JSON: the retired and unknown responses are the same",
       %{retired: [completed | _]} do
    for suffix <- ["", "/pdf", "/json"] do
      retired_conn = get(build_conn(), "/proof/#{completed.id}#{suffix}")
      unknown_conn = get(build_conn(), "/proof/#{@unknown}#{suffix}")
      assert seen(retired_conn) == seen(unknown_conn), suffix
    end

    assert json_response(get(build_conn(), "/proof/#{completed.id}/json"), 404) ==
             %{"error" => "not found"}

    assert json_response(get(build_conn(), "/proof/#{completed.id}/pdf"), 404) ==
             %{"error" => "draw not found"}

    assert redirected_to(get(build_conn(), "/proof/#{completed.id}")) == "/"
  end

  test "the JSON bundle never reaches ProofBundle.build for a retired draw",
       %{retired: [completed | _]} do
    # The retired draw has a lock receipt but no execution receipt. Were
    # ProofBundle.build reached, it would refuse with
    # missing_execution_receipt, a 500; the 404 shows it never runs.
    assert {:error, :missing_execution_receipt} = WallopCore.ProofBundle.build(completed)
    assert json_response(get(build_conn(), "/proof/#{completed.id}/json"), 404)
  end

  test "the live proof page treats a retired draw as unknown", %{retired: retired} do
    for draw <- retired, path <- ["/live/proof/#{draw.id}", "/live/proof/#{draw.id}/x"] do
      unknown_path = String.replace(path, draw.id, @unknown)

      assert live(build_conn(), path) == live(build_conn(), unknown_path), path
      assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), path)
    end
  end

  test "the signed receipts stay served at the receipt endpoint", %{retired: [completed | _]} do
    operator = Ash.get!(WallopCore.Resources.Operator, completed.operator_id, authorize?: false)
    slug = to_string(operator.slug)

    conn = get(build_conn(), "/operator/#{slug}/receipts/#{completed.operator_sequence}")
    assert conn.status == 200
  end

  test "an expired draw keeps its normal page", %{key: key} do
    expired =
      key
      |> open_draw_with_entries()
      |> Ash.Changeset.for_update(:expire, %{})
      |> Ash.update!(authorize?: false)

    conn = get(build_conn(), "/proof/#{expired.id}")
    assert conn.status == 200
    assert conn.resp_body =~ expired.id
  end

  test "a completed lock schema 6 draw keeps its normal page", %{key: key} do
    done = execute_draw(create_draw(key))
    assert get(build_conn(), "/proof/#{done.id}").status == 200
    assert get(build_conn(), "/proof/#{done.id}/json").status == 200
  end
end
