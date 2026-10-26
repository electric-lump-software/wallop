defmodule WallopCore.VaultKeyCheckTest.OtherVault do
  @moduledoc "A second vault, started per test with the ciphers under test."
  use Cloak.Vault, otp_app: :wallop_core
end

defmodule WallopCore.VaultKeyCheckTest.RaisingVault do
  @moduledoc "A vault whose decrypt raises with the ciphertext in the error, as Cloak can."
  def decrypt(ciphertext), do: raise(MatchError, term: ciphertext)
end

defmodule WallopCore.VaultKeyCheckTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  require Ash.Query

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

  describe "when the database can't be read at boot" do
    @describetag :capture_log

    defp flaky_read(failures) do
      counter = :counters.new(1, [])

      read = fn resource, prefix ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) <= failures,
          do: {:error, %DBConnection.ConnectionError{message: "connection refused"}},
          else: real_read(resource, prefix)
      end

      {read, counter}
    end

    defp real_read(resource, prefix) do
      size = byte_size(prefix)

      resource
      |> Ash.Query.filter(fragment("substring(? from 1 for ?) = ?", private_key, ^size, ^prefix))
      |> Ash.Query.limit(1)
      |> Ash.read_one(authorize?: false)
    end

    defp recording_sleep do
      test_pid = self()
      fn ms -> send(test_pid, {:slept, ms}) end
    end

    test "waits and proceeds once the database answers" do
      create_infrastructure_key()
      {read, _} = flaky_read(2)

      assert [{:default, "AES.GCM.V1", {:ok, "infrastructure_signing_keys", _}}] =
               VaultKeyCheck.check!(read: read, sleep: recording_sleep(), db_wait_ms: 180_000)

      assert_received {:slept, 500}
      assert_received {:slept, 1000}
      refute_received {:slept, _}
    end

    test "raises once the wait is used up, having waited no longer than the bound" do
      {read, _} = flaky_read(1_000)

      assert_raise RuntimeError,
                   ~r/could not read infrastructure_signing_keys after waiting 180000 ms/,
                   fn ->
                     VaultKeyCheck.check!(
                       read: read,
                       sleep: recording_sleep(),
                       db_wait_ms: 180_000
                     )
                   end

      slept =
        Stream.repeatedly(fn ->
          receive do
            {:slept, ms} -> ms
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)

      assert Enum.sum(slept) == 180_000
      assert Enum.max(slept) <= 15_000
    end

    test "a wrong key raises at once, without waiting or reading again" do
      create_infrastructure_key()
      {read, counter} = flaky_read(0)
      ciphers = [default: cipher("AES.GCM.V1", @wrong_key)]
      start_supervised!({OtherVault, ciphers: ciphers})

      assert_raise RuntimeError, ~r/:decrypt_failed/, fn ->
        VaultKeyCheck.check!(
          vault: OtherVault,
          ciphers: ciphers,
          read: read,
          sleep: recording_sleep(),
          db_wait_ms: 180_000
        )
      end

      refute_received {:slept, _}
      assert :counters.get(counter, 1) == 1
    end
  end

  test "a decrypt that raises is a failed decrypt, with no ciphertext in the message" do
    {public_key, _seed} = :crypto.generate_key(:eddsa, :ed25519)
    ciphertext = <<1, 10>> <> "AES.GCM.V1" <> <<0xDE, 0xAD, 0xBE, 0xEF, 0x42>>
    insert_infra_key(public_key, ciphertext)

    error =
      assert_raise RuntimeError, ~r/:decrypt_failed/, fn ->
        VaultKeyCheck.check!(vault: WallopCore.VaultKeyCheckTest.RaisingVault)
      end

    message = Exception.message(error)
    refute String.contains?(message, <<0xDE, 0xAD, 0xBE, 0xEF>>)
    refute message =~ ~r/222, 173, 190, 239|DEADBEEF|deadbeef|MatchError/
  end

  test "a truncated ciphertext under a known tag is a failed decrypt, with no ciphertext in the message" do
    {public_key, _seed} = :crypto.generate_key(:eddsa, :ed25519)
    truncated = <<1, 10>> <> "AES.GCM.V1" <> <<0xDE, 0xAD, 0xBE, 0xEF, 0x42>>
    insert_infra_key(public_key, truncated)

    error = assert_raise RuntimeError, ~r/:decrypt_failed/, fn -> VaultKeyCheck.check!() end
    message = Exception.message(error)

    refute String.contains?(message, <<0xDE, 0xAD, 0xBE, 0xEF>>)
    refute message =~ ~r/222, 173, 190, 239|DEADBEEF|deadbeef/
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
