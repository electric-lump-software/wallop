defmodule WallopWeb.ProofStorageTest do
  use ExUnit.Case, async: true

  alias WallopWeb.ProofStorage

  setup do
    # Each test gets a fresh tmp dir so they don't collide
    root = Path.join(System.tmp_dir!(), "proof_storage_#{System.unique_integer([:positive])}")
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

    {:ok, root: root}
  end

  describe "filesystem backend" do
    test "put then get round-trips" do
      assert :ok = ProofStorage.put("test-draw-1", "PDF BYTES")
      assert {:ok, "PDF BYTES"} = ProofStorage.get("test-draw-1")
    end

    test "get returns :not_found for unknown id" do
      assert {:error, :not_found} = ProofStorage.get("nonexistent-draw")
    end

    test "exists? reflects put state" do
      refute ProofStorage.exists?("missing-draw")
      :ok = ProofStorage.put("present-draw", "x")
      assert ProofStorage.exists?("present-draw")
    end

    test "put overwrites" do
      :ok = ProofStorage.put("overwrite-draw", "v1")
      :ok = ProofStorage.put("overwrite-draw", "v2")
      assert {:ok, "v2"} = ProofStorage.get("overwrite-draw")
    end
  end
end
