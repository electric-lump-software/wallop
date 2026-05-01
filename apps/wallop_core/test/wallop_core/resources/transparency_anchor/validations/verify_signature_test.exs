defmodule WallopCore.Resources.TransparencyAnchor.Validations.VerifySignatureTest do
  @moduledoc """
  Regression: anchor `:create` self-verifies the supplied signature
  against the supplied merkle_root + signing_key_id. Producer-side
  defence-in-depth (the AnchorWorker is the only legitimate caller and
  builds these three fields consistently by construction; this test
  asserts that a bypassing caller cannot insert an inconsistent row).
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Protocol
  alias WallopCore.Resources.TransparencyAnchor

  setup do
    ensure_infrastructure_key()
    :ok
  end

  defp infra_key do
    [key | _] =
      WallopCore.Resources.InfrastructureSigningKey
      |> Ash.Query.sort(valid_from: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    key
  end

  defp infra_private_key(key) do
    {:ok, private_key} = WallopCore.Vault.decrypt(key.private_key)
    private_key
  end

  defp build_anchor_attrs(merkle_root, signature, signing_key_id) do
    %{
      merkle_root: merkle_root,
      receipt_count: 0,
      to_receipt_id: Ecto.UUID.generate(),
      anchored_at: DateTime.utc_now(),
      operator_receipts_root: :crypto.hash(:sha256, <<>>),
      execution_receipts_root: :crypto.hash(:sha256, <<>>),
      execution_receipt_count: 0,
      infrastructure_signature: signature,
      signing_key_id: signing_key_id
    }
  end

  test "accepts a row whose signature verifies against the merkle_root + key" do
    key = infra_key()
    merkle_root = :crypto.hash(:sha256, "anchor-test-root")
    signature = Protocol.sign_receipt(merkle_root, infra_private_key(key))

    attrs = build_anchor_attrs(merkle_root, signature, key.key_id)

    assert {:ok, _} =
             TransparencyAnchor
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(authorize?: false)
  end

  test "rejects a row whose signature does not verify against the merkle_root" do
    key = infra_key()
    merkle_root = :crypto.hash(:sha256, "anchor-test-root")
    other_root = :crypto.hash(:sha256, "different-root")
    bad_signature = Protocol.sign_receipt(other_root, infra_private_key(key))

    attrs = build_anchor_attrs(merkle_root, bad_signature, key.key_id)

    assert {:error, %Ash.Error.Invalid{}} =
             TransparencyAnchor
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(authorize?: false)
  end

  test "rejects a row whose signing_key_id does not exist in the keyring" do
    key = infra_key()
    merkle_root = :crypto.hash(:sha256, "anchor-test-root")
    signature = Protocol.sign_receipt(merkle_root, infra_private_key(key))

    attrs = build_anchor_attrs(merkle_root, signature, "deadbeef")

    assert {:error, %Ash.Error.Invalid{}} =
             TransparencyAnchor
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(authorize?: false)
  end
end
