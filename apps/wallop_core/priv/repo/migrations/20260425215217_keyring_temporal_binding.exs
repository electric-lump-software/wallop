defmodule WallopCore.Repo.Migrations.KeyringTemporalBinding do
  @moduledoc """
  Keyring backdating mitigation.

  Adds a symmetric 60-second CHECK constraint on `valid_from` vs
  `inserted_at` for both signing-key tables. Prevents code paths
  running with `authorize?: false` (mix tasks, seeds, future admin
  endpoints, compromised admin credentials) from inserting keyring
  rows whose `valid_from` is outside a tight window around
  `inserted_at`.

  Without this constraint, a back-dated row (e.g. `valid_from =
  '2020-01-01'`) becomes the selected signer on any current
  `valid_from <= now ORDER BY valid_from DESC` lookup, allowing a
  malicious admin to forge new receipts claiming historical
  `locked_at` times. The CHECK closes that off at the storage
  layer, complementing the verifier-side first-existence rule in
  `spec/protocol.md` §4.2.4.

  Forward dating is rejected for the same reason — a 1.x append-only
  keyring should not have optionality around when a key starts being
  valid. Scheduled rotations, if ever needed, get a dedicated action
  with its own audit trail rather than widening this tolerance.
  """

  use Ecto.Migration

  @tables ["operator_signing_keys", "infrastructure_signing_keys"]

  def up do
    for table <- @tables do
      preflight_check(table)
      add_constraint(table)
    end
  end

  def down do
    for table <- @tables do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{constraint_name(table)}")
    end
  end

  defp preflight_check(table) do
    %{rows: rows} =
      repo().query!("""
      SELECT id FROM #{table}
      WHERE valid_from NOT BETWEEN inserted_at - INTERVAL '60 seconds'
                               AND inserted_at + INTERVAL '60 seconds'
      """)

    if rows != [] do
      ids =
        rows
        |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)
        |> Enum.join(", ")

      raise """
      Keyring temporal binding migration aborted: rows in #{table} have
      valid_from outside the ±60 second window from inserted_at. Manual
      remediation required before this constraint can attach.

      Offending IDs: #{ids}
      """
    end
  end

  defp add_constraint(table) do
    execute("""
    ALTER TABLE #{table}
      ADD CONSTRAINT #{constraint_name(table)}
      CHECK (
        valid_from BETWEEN inserted_at - INTERVAL '60 seconds'
                       AND inserted_at + INTERVAL '60 seconds'
      )
    """)
  end

  defp constraint_name(table), do: "#{table}_valid_from_within_skew"
end
