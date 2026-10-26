defmodule WallopCore.VaultKeyCheckTest.OtherVault do
  @moduledoc "A second vault, started per test with the ciphers under test."
  use Cloak.Vault, otp_app: :wallop_core
end

defmodule WallopCore.VaultKeyCheckTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias Cloak.Ciphers.AES.GCM
  alias WallopCore.Resources.InfrastructureSigningKey
  alias WallopCore.VaultKeyCheck
  alias WallopCore.VaultKeyCheckTest.OtherVault

  @test_key Base.decode64!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
  @old_key :crypto.strong_rand_bytes(32)
  @wrong_key :crypto.strong_rand_bytes(32)

  defp cipher(tag, key), do: {GCM, tag: tag, key: key, iv_length: 12}

  defp check_with(ciphers) do
    start_supervised!({OtherVault, ciphers: ciphers})
    VaultKeyCheck.check!(vault: OtherVault, ciphers: ciphers)
  end

  defp insert_infra_key(public_key, private_key_ciphertext) do
    InfrastructureSigningKey
    |> Ash.Changeset.for_create(:create, %{
      key_id: WallopCore.Protocol.key_id(public_key),
      public_key: public_key,
      private_key: private_key_ciphertext,
      valid_from: DateTime.add(DateTime.utc_now(), -30, :second)
    })
    |> Ash.create!(authorize?: false)
  end

  defp insert_infra_key_under(tag, key) do
    {public_key, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, ciphertext} = GCM.encrypt(seed, tag: tag, key: key, iv_length: 12)
    insert_infra_key(public_key, ciphertext)
  end

  describe "with the configured key" do
    test "passes on an infrastructure key row and names it" do
      key = create_infrastructure_key()

      assert [{:default, "AES.GCM.V1", {:ok, "infrastructure_signing_keys", key_id}}] =
               VaultKeyCheck.check!()

      assert key_id == key.key_id
    end

    test "falls back to an operator key row when there is no infrastructure key" do
      create_operator()

      assert [{:default, "AES.GCM.V1", {:ok, "operator_signing_keys", _}}] =
               VaultKeyCheck.check!()
    end

    test "skips a cipher whose tag no row carries" do
      assert VaultKeyCheck.check!() == [{:default, "AES.GCM.V1", :skipped}]
    end
  end

  describe "refuses to boot" do
    test "when VAULT_KEY is not the key the rows were written with" do
      create_infrastructure_key()

      assert_raise RuntimeError, ~r/cipher :default \(AES\.GCM\.V1\).*:decrypt_failed/s, fn ->
        check_with(default: cipher("AES.GCM.V1", @wrong_key))
      end
    end

    test "when a row's public key does not match its private key" do
      {_other_public, seed} = :crypto.generate_key(:eddsa, :ed25519)
      {public_key, _} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, ciphertext} = WallopCore.Vault.encrypt(seed)
      insert_infra_key(public_key, ciphertext)

      assert_raise RuntimeError, ~r/:public_key_mismatch/, fn -> VaultKeyCheck.check!() end
    end

    test "in dual-key mode, when VAULT_KEY_OLD is wrong" do
      create_infrastructure_key()
      insert_infra_key_under("AES.GCM.V0", @old_key)

      assert_raise RuntimeError, ~r/cipher :retired \(AES\.GCM\.V0\).*:decrypt_failed/s, fn ->
        check_with(
          default: cipher("AES.GCM.V1", @test_key),
          retired: cipher("AES.GCM.V0", @wrong_key)
        )
      end
    end

    test "before any later child starts, as a supervisor child" do
      create_infrastructure_key()
      ciphers = [default: cipher("AES.GCM.V1", @wrong_key)]
      start_supervised!({OtherVault, ciphers: ciphers})
      test_pid = self()

      later_child =
        Supervisor.child_spec({Agent, fn -> send(test_pid, :later_child_started) end},
          id: :later_child
        )

      Process.flag(:trap_exit, true)

      assert {:error, {:shutdown, {:failed_to_start_child, VaultKeyCheck, _}}} =
               Supervisor.start_link(
                 [{VaultKeyCheck, vault: OtherVault, ciphers: ciphers}, later_child],
                 strategy: :one_for_one
               )

      refute_received :later_child_started
    end
  end

  test "in dual-key mode with both keys right, checks each cipher on its own row" do
    create_infrastructure_key()
    insert_infra_key_under("AES.GCM.V0", @old_key)

    assert [
             {:default, "AES.GCM.V1", {:ok, "infrastructure_signing_keys", _}},
             {:retired, "AES.GCM.V0", {:ok, "infrastructure_signing_keys", _}}
           ] =
             check_with(
               default: cipher("AES.GCM.V1", @test_key),
               retired: cipher("AES.GCM.V0", @old_key)
             )
  end

  test "the failure message carries no key material" do
    {public_key, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, ciphertext} = WallopCore.Vault.encrypt(seed)
    row = insert_infra_key(public_key, ciphertext)

    error =
      assert_raise RuntimeError, fn ->
        check_with(default: cipher("AES.GCM.V1", @wrong_key))
      end

    message = Exception.message(error)
    assert message =~ "infrastructure_signing_keys"
    assert message =~ row.key_id

    for secret <- [seed, ciphertext, @wrong_key, @test_key],
        form <-
          [secret, Base.encode16(secret), Base.encode16(secret, case: :lower)] ++
            [Base.encode64(secret)] do
      refute String.contains?(message, form)
    end
  end

  test "sits between the vault and Oban in the application's children" do
    previous = Application.get_env(:wallop_core, :vault_key_check)
    Application.put_env(:wallop_core, :vault_key_check, true)
    on_exit(fn -> Application.put_env(:wallop_core, :vault_key_check, previous) end)

    ids = Enum.map(WallopCore.Application.children(), &child_id/1)
    position = fn id -> Enum.find_index(ids, &(&1 == id)) end

    assert position.(WallopCore.Vault) < position.(VaultKeyCheck)
    assert position.(VaultKeyCheck) < position.(Phoenix.PubSub)
    assert position.(VaultKeyCheck) < position.(Oban)
  end

  defp child_id({module, _opts}), do: module
  defp child_id(%{start: {module, _, _}}), do: module
  defp child_id(module) when is_atom(module), do: module
end
