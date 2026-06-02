defmodule Mix.Tasks.Wallop.Vault.VerifyRotationTest do
  use WallopCore.DataCase, async: false

  import ExUnit.CaptureIO
  import WallopCore.TestHelpers

  alias Mix.Tasks.Wallop.Vault.VerifyRotation

  require Ash.Query

  # DataCase wraps each test in a Repo sandbox transaction that rolls
  # back at teardown — no per-test cleanup needed.

  describe "happy path" do
    test "returns :ok and reports tags when every row carries the current tag" do
      create_infrastructure_key()
      operator = create_operator()
      create_api_key_for_operator(operator)

      {result, output} = run_and_capture()

      assert result == :ok
      assert output =~ "current tag:  AES.GCM.V1"
      assert output =~ "previous tag: AES.GCM.V0"
      assert output =~ "All rows carry the current tag"
      assert output =~ "operator_signing_keys.private_key"
      assert output =~ "infrastructure_signing_keys.private_key"
      assert output =~ "api_keys.webhook_secret"
    end
  end

  describe "rotation incomplete" do
    test "returns :rotation_incomplete when a row holds a previous-tag blob" do
      _ = insert_infrastructure_key_with_blob(synthetic_previous_tag_blob())

      {result, _output} = run_and_capture()

      assert result == {:error, :rotation_incomplete}
    end

    test "previous-tag count surfaces on the right column line" do
      _ = insert_infrastructure_key_with_blob(synthetic_previous_tag_blob())

      {_result, output} = run_and_capture()

      [infra_line] =
        output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "infrastructure_signing_keys.private_key"))

      # Layout: ... current previous unknown total
      #          0       1        0       1
      assert infra_line =~ ~r/\s0\s+1\s+0\s+1\s*$/
    end

    test "run/1 exits with shutdown code 1 in this state" do
      _ = insert_infrastructure_key_with_blob(synthetic_previous_tag_blob())

      result =
        try do
          capture_io(:stderr, fn ->
            capture_io(fn -> VerifyRotation.run([]) end)
          end)
        catch
          :exit, {:shutdown, 1} -> :exited_cleanly
        end

      assert result == :exited_cleanly
    end
  end

  describe "unknown tag" do
    test "returns :unknown_tag when a row carries a tag this build does not recognise" do
      _ = insert_infrastructure_key_with_blob(synthetic_unknown_tag_blob())

      {result, _output} = run_and_capture()

      assert result == {:error, :unknown_tag}
    end
  end

  # Runs `inspect_and_report/0` while capturing both stdout and stderr.
  # Returns `{return_value, combined_stdout_output}`.
  defp run_and_capture do
    # with_io/1 returns {function_result, captured_output}.
    {{return_value, stdout}, _stderr} =
      with_io(:standard_error, fn ->
        with_io(fn -> VerifyRotation.inspect_and_report() end)
      end)

    {return_value, stdout}
  end

  defp insert_infrastructure_key_with_blob(blob) do
    {public_key, _priv} = :crypto.generate_key(:eddsa, :ed25519)
    key_id = WallopCore.Protocol.key_id(public_key)

    WallopCore.Resources.InfrastructureSigningKey
    |> Ash.Changeset.for_create(:create, %{
      key_id: key_id,
      public_key: public_key,
      private_key: blob,
      valid_from: DateTime.add(DateTime.utc_now(), -30, :second)
    })
    |> Ash.create!(authorize?: false)
  end

  # A byte-accurate fake of a Cloak ciphertext encoded under the previous
  # tag. The verify task only inspects the tag prefix — it never decrypts
  # — so we don't need a real V0 cipher, just a well-formed TLV envelope.
  defp synthetic_previous_tag_blob do
    tag = "AES.GCM.V0"
    <<1, byte_size(tag)>> <> tag <> :crypto.strong_rand_bytes(48)
  end

  defp synthetic_unknown_tag_blob do
    tag = "AES.GCM.VX"
    <<1, byte_size(tag)>> <> tag <> :crypto.strong_rand_bytes(48)
  end
end
