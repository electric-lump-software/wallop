defmodule WallopWeb.ProofPdfControllerTest do
  use WallopWeb.ConnCase, async: false

  import WallopCore.TestHelpers

  alias WallopWeb.ProofStorage

  setup do
    # Each test gets a fresh tmp dir
    root = Path.join(System.tmp_dir!(), "pdf_ctrl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    original = Application.get_env(:wallop_web, :proof_storage)

    Application.put_env(:wallop_web, :proof_storage,
      backend: WallopWeb.ProofStorage.Filesystem,
      filesystem: [root: root]
    )

    on_exit(fn ->
      File.rm_rf!(root)
      Application.put_env(:wallop_web, :proof_storage, original)
    end)

    :ok
  end

  describe "GET /proof/:id/pdf" do
    test "returns 404 for unknown draw", %{conn: conn} do
      conn = get(conn, "/proof/00000000-0000-0000-0000-000000000000/pdf")
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] =~ "not found"
    end

    test "returns 404 for in-progress (open) draw", %{conn: conn} do
      api_key = create_api_key()

      {:ok, draw} =
        WallopCore.Resources.Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create()

      conn = get(conn, "/proof/#{draw.id}/pdf")
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] =~ "completed"
    end

    test "serves a cached PDF for a terminal draw without invoking ChromicPDF", %{conn: conn} do
      api_key = create_api_key()
      draw = create_draw(api_key)

      # Force the draw into a terminal state via direct SQL. The
      # immutability trigger forbids awaiting_entropy → completed
      # directly, so we bypass the trigger with session_replication_role
      # = replica for this one test-only UPDATE. session_replication_role
      # is a session-level setting, so both statements must run on the
      # same connection — wrapping in a transaction guarantees that.
      WallopCore.Repo.transaction(fn ->
        WallopCore.Repo.query!("SET LOCAL session_replication_role = 'replica'")

        WallopCore.Repo.query!(
          "UPDATE draws SET status = 'completed' WHERE id = $1",
          [Ecto.UUID.dump!(draw.id)]
        )
      end)

      # Pre-populate the cache so the controller doesn't need to call ChromicPDF
      :ok = ProofStorage.put(draw.id, "%PDF-1.4 fake bytes")

      conn = get(conn, "/proof/#{draw.id}/pdf")
      assert conn.status == 200
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/pdf")

      assert ["public, max-age=31536000, immutable"] =
               Plug.Conn.get_resp_header(conn, "cache-control")

      assert ["inline; filename=\"wallop-proof-" <> _] =
               Plug.Conn.get_resp_header(conn, "content-disposition")

      assert conn.resp_body == "%PDF-1.4 fake bytes"
    end
  end
end
