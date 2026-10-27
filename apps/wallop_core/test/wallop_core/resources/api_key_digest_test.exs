defmodule WallopCore.Resources.ApiKeyDigestTest do
  use WallopCore.DataCase, async: true

  import WallopCore.TestHelpers

  alias Ecto.Adapters.SQL
  alias WallopCore.Resources.ApiKey
  alias WallopCore.Resources.ApiKey.Digest

  test "digest is SHA-256 of the label, a zero byte and the key" do
    assert Digest.compute("wallop_abc") ==
             :crypto.hash(:sha256, "wallop/api-key/v1" <> <<0>> <> "wallop_abc")
  end

  test "new keys are created with their digest" do
    api_key = create_api_key()
    raw_key = api_key.__metadata__.raw_key
    stored = Ash.get!(ApiKey, api_key.id, authorize?: false)
    assert stored.key_digest == Digest.compute(raw_key)
    assert Bcrypt.verify_pass(raw_key, stored.key_hash)
  end

  test "record_key_digest only writes a missing digest" do
    api_key = create_api_key()
    raw_key = api_key.__metadata__.raw_key

    SQL.query!(
      WallopCore.Repo,
      "UPDATE api_keys SET key_digest = NULL WHERE id = $1",
      [
        Ecto.UUID.dump!(api_key.id)
      ]
    )

    stored = Ash.get!(ApiKey, api_key.id, authorize?: false)
    assert stored.key_digest == nil

    assert {:ok, updated} =
             stored
             |> Ash.Changeset.for_update(:record_key_digest, %{
               key_digest: Digest.compute(raw_key)
             })
             |> Ash.update(authorize?: false)

    assert updated.key_digest == Digest.compute(raw_key)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             stored
             |> Ash.Changeset.for_update(:record_key_digest, %{
               key_digest: :crypto.strong_rand_bytes(32)
             })
             |> Ash.update(authorize?: false)

    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
    assert Ash.get!(ApiKey, api_key.id, authorize?: false).key_digest == Digest.compute(raw_key)
  end

  test "external callers can't record a digest" do
    api_key = create_api_key()

    assert {:error, %Ash.Error.Forbidden{}} =
             api_key
             |> Ash.Changeset.for_update(
               :record_key_digest,
               %{key_digest: :crypto.strong_rand_bytes(32)},
               actor: api_key
             )
             |> Ash.update()
  end

  test "the database rejects a digest that isn't 32 bytes" do
    api_key = create_api_key()

    assert_raise Postgrex.Error, ~r/api_keys_key_digest_length/, fn ->
      SQL.query!(
        WallopCore.Repo,
        "UPDATE api_keys SET key_digest = $1 WHERE id = $2",
        [
          <<1, 2, 3>>,
          Ecto.UUID.dump!(api_key.id)
        ]
      )
    end
  end
end
