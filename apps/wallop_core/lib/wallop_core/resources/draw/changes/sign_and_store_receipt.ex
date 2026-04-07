defmodule WallopCore.Resources.Draw.Changes.SignAndStoreReceipt do
  @moduledoc """
  Signs an operator commitment receipt at draw lock time and inserts it into
  `operator_receipts` in the same transaction. If the actor has no operator,
  this change is a no-op (backward compatible).

  If anything fails — current signing key resolution, private key decryption,
  signing, receipt insert — the entire lock action rolls back via Ash's
  before_action error path. The draw stays `:open` and no sequence is burned.
  """
  use Ash.Resource.Change

  alias WallopCore.Protocol
  alias WallopCore.Resources.{OperatorReceipt, OperatorSigningKey}
  alias WallopCore.Vault

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &sign/1)
  end

  defp sign(changeset) do
    draw = changeset.data

    case draw.operator_id do
      nil ->
        changeset

      operator_id ->
        do_sign(changeset, draw, operator_id)
    end
  end

  defp do_sign(changeset, draw, operator_id) do
    locked_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, operator} <- load_operator(operator_id),
         {:ok, signing_key} <- load_current_signing_key(operator_id, locked_at),
         {:ok, private_key} <- decrypt_private_key(signing_key.private_key),
         commitment_hash <- Ash.Changeset.get_attribute(changeset, :entry_hash) do
      payload =
        Protocol.build_receipt_payload(%{
          operator_id: operator.id,
          operator_slug: operator.slug,
          sequence: draw.operator_sequence,
          draw_id: draw.id,
          commitment_hash: commitment_hash,
          entry_hash: commitment_hash,
          locked_at: locked_at,
          signing_key_id: signing_key.key_id
        })

      signature = Protocol.sign_receipt(payload, private_key)

      Ash.Changeset.after_action(changeset, fn _cs, draw ->
        persist_receipt(draw, operator.id, signature, payload, locked_at, signing_key.key_id)
      end)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :receipt,
          message: "failed to sign operator receipt: #{inspect(reason)}"
        )
    end
  end

  defp persist_receipt(draw, operator_id, signature, payload, locked_at, key_id) do
    case insert_receipt(operator_id, draw, signature, payload, locked_at, key_id) do
      {:ok, _receipt} -> {:ok, draw}
      {:error, error} -> {:error, error}
    end
  end

  defp load_operator(operator_id) do
    case Ash.get(WallopCore.Resources.Operator, operator_id, authorize?: false) do
      {:ok, op} -> {:ok, op}
      {:error, e} -> {:error, e}
    end
  end

  defp load_current_signing_key(operator_id, now) do
    OperatorSigningKey
    |> Ash.Query.filter(operator_id == ^operator_id and valid_from <= ^now)
    |> Ash.Query.sort(valid_from: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [key]} -> {:ok, key}
      {:ok, []} -> {:error, :no_signing_key}
      {:error, e} -> {:error, e}
    end
  end

  defp decrypt_private_key(encrypted) do
    case Vault.decrypt(encrypted) do
      {:ok, raw} -> {:ok, raw}
      {:error, e} -> {:error, e}
    end
  end

  defp insert_receipt(operator_id, draw, signature, payload, locked_at, key_id) do
    OperatorReceipt
    |> Ash.Changeset.for_create(:create, %{
      operator_id: operator_id,
      draw_id: draw.id,
      sequence: draw.operator_sequence,
      commitment_hash: draw.entry_hash,
      entry_hash: draw.entry_hash,
      locked_at: locked_at,
      signing_key_id: key_id,
      payload_jcs: payload,
      signature: signature
    })
    |> Ash.create(authorize?: false)
  end
end
