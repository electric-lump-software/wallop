defmodule WallopCore.Resources.TransparencyAnchor.Validations.VerifySignature do
  @moduledoc """
  Defence-in-depth: re-verifies that the supplied
  `infrastructure_signature` is a valid Ed25519 signature over the
  supplied `merkle_root`, using the public key referenced by
  `signing_key_id`.

  The producer (`AnchorWorker`) only inserts rows where these three
  fields are consistent by construction. This validation closes a
  belt-and-braces gap: if any future code path constructs an anchor row
  outside `AnchorWorker` (a migration, a one-off mix task, a release
  task with `authorize?: false`), it cannot insert a row whose
  signature does not in fact verify against the named key. Verifiers
  read the row off the wire and re-check the same relation; this just
  asserts producer-side that the row was honest at insert time.

  Cost: one DB lookup of the infrastructure key by `signing_key_id`,
  plus one Ed25519 verify. Both are sub-millisecond at the rate at
  which anchors are produced (cron-driven, not request-path).

  Mirrors the pattern of `Protocol.assert_key_consistency/3` in shape
  and intent (defence-in-depth signature verification at the producer
  boundary).
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias WallopCore.Protocol
  alias WallopCore.Resources.InfrastructureSigningKey

  @impl true
  def validate(changeset, _opts, _context) do
    merkle_root = Ash.Changeset.get_attribute(changeset, :merkle_root)
    signature = Ash.Changeset.get_attribute(changeset, :infrastructure_signature)
    signing_key_id = Ash.Changeset.get_attribute(changeset, :signing_key_id)

    # Fall-through to :ok on missing fields. Required-ness is enforced
    # by the resource's `allow_nil?` attributes elsewhere — letting that
    # produce the canonical "field is required" error avoids surfacing a
    # misleading "signature does not verify" error on a row that's just
    # missing inputs.
    cond do
      not is_binary(merkle_root) ->
        :ok

      not is_binary(signature) ->
        :ok

      not is_binary(signing_key_id) ->
        :ok

      true ->
        verify(merkle_root, signature, signing_key_id)
    end
  end

  defp verify(merkle_root, signature, signing_key_id) do
    case load_public_key(signing_key_id) do
      {:ok, public_key} ->
        if Protocol.verify_receipt(merkle_root, signature, public_key) do
          :ok
        else
          {:error,
           field: :infrastructure_signature,
           message:
             "signature does not verify against the merkle_root under signing_key_id #{signing_key_id}"}
        end

      :error ->
        {:error,
         field: :signing_key_id,
         message: "no infrastructure signing key found with key_id #{signing_key_id}"}
    end
  end

  defp load_public_key(signing_key_id) do
    InfrastructureSigningKey
    |> Ash.Query.filter(key_id == ^signing_key_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [%{public_key: public_key}]} when is_binary(public_key) -> {:ok, public_key}
      _ -> :error
    end
  end
end
