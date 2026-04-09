defmodule WallopCore.Repo.Migrations.ExtendTransparencyAnchors do
  @moduledoc """
  Add dual sub-tree roots and infrastructure signature to transparency anchors.

  The anchor's `merkle_root` becomes a combined root:

      SHA256("wallop-anchor-v1" || operator_receipts_root || execution_receipts_root)

  The `"wallop-anchor-v1"` prefix provides domain separation from both
  leaf hashes (`0x00`) and internal Merkle nodes (`0x01`), avoiding
  structural ambiguity with RFC 6962 tree nodes.

  The `infrastructure_signature` signs the combined root with the infra key,
  making the transparency log itself infra-key-signed.

  Existing anchors (pre-execution-receipt) have null values for the new columns.
  """
  use Ecto.Migration

  def change do
    # Disable the immutability trigger temporarily so we can ALTER the table
    # (the trigger blocks all modifications, but ALTER TABLE isn't DML)
    # Actually ALTER TABLE ADD COLUMN is DDL, not blocked by the trigger.

    alter table(:transparency_anchors) do
      add :operator_receipts_root, :binary
      add :execution_receipts_root, :binary
      add :execution_receipt_count, :integer, default: 0
      add :infrastructure_signature, :binary
      add :signing_key_id, :string
    end
  end
end
