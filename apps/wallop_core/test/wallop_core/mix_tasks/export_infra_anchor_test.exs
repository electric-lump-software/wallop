defmodule Mix.Tasks.Wallop.ExportInfraAnchorTest do
  use WallopCore.DataCase, async: false

  import ExUnit.CaptureIO
  import WallopCore.TestHelpers

  alias Mix.Tasks.Wallop.ExportInfraAnchor
  alias WallopCore.Resources.InfrastructureSigningKey

  require Ash.Query

  setup do
    # Each test runs against an empty infra keyring; mint deterministically
    # in the test body to control ordering.
    InfrastructureSigningKey
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    :ok
  end

  describe "JSON output (default)" do
    test "emits a single anchor record for a single keyring row" do
      key = create_infrastructure_key()

      output =
        capture_io(fn ->
          ExportInfraAnchor.run([])
        end)

      [record] = Jason.decode!(output)

      assert record["key_id"] == key.key_id
      assert record["public_key_hex"] == Base.encode16(key.public_key, case: :lower)
      assert record["revoked_at"] == nil
      assert record["inserted_at"] =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

      # Private key MUST NOT appear in the output.
      refute output =~ Base.encode16(key.private_key, case: :lower)
      refute output =~ "private"
    end

    test "emits multiple records sorted ascending by inserted_at" do
      # The keyring's `valid_from`/`inserted_at` CHECK constraint forces
      # them within ±60s of each other, so we can't backdate. Create
      # three keys in sequence — `inserted_at` is microsecond-precision
      # so each row gets a strictly later timestamp than the previous.
      _k1 = create_infrastructure_key()
      _k2 = create_infrastructure_key()
      _k3 = create_infrastructure_key()

      output =
        capture_io(fn ->
          ExportInfraAnchor.run([])
        end)

      records = Jason.decode!(output)
      assert length(records) == 3

      timestamps = Enum.map(records, & &1["inserted_at"])
      assert timestamps == Enum.sort(timestamps)
      # Strictly ascending — every row has a different inserted_at.
      assert Enum.uniq(timestamps) == timestamps
    end

    test "every record has the canonical four-field anchor shape" do
      create_infrastructure_key()

      output =
        capture_io(fn ->
          ExportInfraAnchor.run([])
        end)

      [record] = Jason.decode!(output)

      assert Map.keys(record) |> Enum.sort() == [
               "inserted_at",
               "key_id",
               "public_key_hex",
               "revoked_at"
             ]
    end
  end

  describe "Rust output (--rust flag)" do
    test "emits a const-array snippet directly pasteable into anchors.rs" do
      key = create_infrastructure_key()

      output =
        capture_io(fn ->
          ExportInfraAnchor.run(["--rust"])
        end)

      assert output =~ "pub const ANCHORS: &[Anchor] = &["
      assert output =~ "Anchor {"
      assert output =~ ~s|key_id: "#{key.key_id}"|
      assert output =~ ~s|public_key_hex: "#{Base.encode16(key.public_key, case: :lower)}"|
      assert output =~ "revoked_at: None,"
      assert output =~ "];"
    end

    test "Rust snippet does not leak private key material" do
      key = create_infrastructure_key()

      output =
        capture_io(fn ->
          ExportInfraAnchor.run(["--rust"])
        end)

      refute output =~ Base.encode16(key.private_key, case: :lower)
      refute output =~ "private"
    end
  end

  describe "empty keyring" do
    test "exits with error and a clear message when no keys exist" do
      # `setup` already cleared the keyring.
      result =
        try do
          capture_io(:stderr, fn ->
            ExportInfraAnchor.run([])
          end)
        catch
          :exit, {:shutdown, 1} -> :exited_cleanly
        end

      assert result == :exited_cleanly
    end
  end
end
