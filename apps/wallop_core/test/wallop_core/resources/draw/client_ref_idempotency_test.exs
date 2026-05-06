defmodule WallopCore.Resources.Draw.ClientRefIdempotencyTest do
  @moduledoc """
  Sharp-edge regressions for `Draw.add_entries` idempotency (ADR-0012).

  Each test guards a permanent commitment from the ADR. The matrix:

  | # | Concern                                  | What's at stake                                            |
  |---|------------------------------------------|------------------------------------------------------------|
  | 1 | 409 on payload mismatch                  | Replay safety — silent merge would be the worst failure    |
  | 2 | Byte-stable retry across JSON reorder    | Honest retries must not 409 on serialisation differences   |
  | 3 | Plaintext NEVER reaches log/telemetry    | Goal-5 boundary; operator-supplied opaque text             |
  | 4 | Prune-at-lock is same-transaction        | Crash window between prune + lock-commit is closed         |
  | 5 | Receipt invariance (lock receipt)        | Idempotency state is operational, never signed             |
  | 6 | Receipt invariance (execution receipt)   | Same — wipe table mid-flight, signed artefacts unchanged   |
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Repo
  alias WallopCore.Resources.{AddEntriesIdempotency, Draw}

  describe "409 on payload mismatch (same client_ref, different multiset)" do
    test "second call with mismatched entries returns idempotency conflict" do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      shared_ref = Ash.UUID.generate()

      # First batch lands cleanly.
      _draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"weight" => 1}, %{"weight" => 2}], client_ref: shared_ref},
          actor: api_key
        )
        |> Ash.update!()

      # Second call, SAME client_ref, DIFFERENT entries → must 409.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               draw
               |> Ash.Changeset.for_update(
                 :add_entries,
                 %{entries: [%{"weight" => 1}, %{"weight" => 99}], client_ref: shared_ref},
                 actor: api_key
               )
               |> Ash.update()

      assert Enum.any?(errors, fn e ->
               match?(%WallopCore.Errors.IdempotencyConflict{}, e)
             end),
             "expected an IdempotencyConflict error, got: #{inspect(errors)}"
    end

    test "second call with IDENTICAL entries replays cached entry_ids (no double-insert)" do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      shared_ref = Ash.UUID.generate()

      first =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"weight" => 1}, %{"weight" => 2}], client_ref: shared_ref},
          actor: api_key
        )
        |> Ash.update!()

      first_uuids = Ash.Resource.get_metadata(first, :inserted_entries)

      # Replay must return the same uuids.
      replayed =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"weight" => 1}, %{"weight" => 2}], client_ref: shared_ref},
          actor: api_key
        )
        |> Ash.update!()

      replayed_uuids = Ash.Resource.get_metadata(replayed, :inserted_entries)

      assert replayed_uuids == first_uuids
      assert length(WallopCore.Entries.load_for_draw(draw.id)) == 2
    end
  end

  describe "byte-stable retry (entries in different order, same multiset)" do
    test "retries with reordered entries replay against the same digest" do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      shared_ref = Ash.UUID.generate()

      first =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{
            entries: [%{"weight" => 1}, %{"weight" => 2}, %{"weight" => 3}],
            client_ref: shared_ref
          },
          actor: api_key
        )
        |> Ash.update!()

      first_uuids = Ash.Resource.get_metadata(first, :inserted_entries)

      # Same logical multiset, presented in a different order: must replay.
      replayed =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{
            entries: [%{"weight" => 3}, %{"weight" => 1}, %{"weight" => 2}],
            client_ref: shared_ref
          },
          actor: api_key
        )
        |> Ash.update!()

      replayed_uuids = Ash.Resource.get_metadata(replayed, :inserted_entries)

      assert replayed_uuids == first_uuids
      assert length(WallopCore.Entries.load_for_draw(draw.id)) == 3
    end
  end

  describe "plaintext client_ref never appears in logs or telemetry" do
    test "log capture from the action carries no plaintext token" do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      # Use a distinctive plaintext we can grep for in logs.
      sentinel = "wallop-leak-canary-#{Ash.UUID.generate()}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          draw
          |> Ash.Changeset.for_update(
            :add_entries,
            %{entries: [%{"weight" => 1}], client_ref: sentinel},
            actor: api_key
          )
          |> Ash.update!()
        end)

      refute String.contains?(log, sentinel),
             "plaintext client_ref leaked into log output: #{log}"
    end

    test "stored idempotency row contains digests, never plaintext" do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      sentinel = "another-leak-canary-#{Ash.UUID.generate()}"

      draw
      |> Ash.Changeset.for_update(
        :add_entries,
        %{entries: [%{"weight" => 1}], client_ref: sentinel},
        actor: api_key
      )
      |> Ash.update!()

      [row] = Repo.all(AddEntriesIdempotency)

      # Storage shape: bytea (32-byte raw SHA-256), not text/hex.
      assert is_binary(row.client_ref_digest)
      assert byte_size(row.client_ref_digest) == 32
      assert is_binary(row.payload_digest)
      assert byte_size(row.payload_digest) == 32

      # The plaintext sentinel must not appear anywhere on the row.
      stringified = inspect(row)
      refute String.contains?(stringified, sentinel)
    end
  end

  describe "prune-at-lock is same-transaction" do
    test "successful lock removes idempotency rows for the draw" do
      api_key = create_api_key()

      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
        |> Ash.create!()

      # Two distinct batches → two idempotency rows.
      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"weight" => 1}], client_ref: Ash.UUID.generate()},
          actor: api_key
        )
        |> Ash.update!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"weight" => 1}], client_ref: Ash.UUID.generate()},
          actor: api_key
        )
        |> Ash.update!()

      assert Repo.aggregate(AddEntriesIdempotency, :count) == 2

      _locked =
        draw
        |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
        |> Ash.update!()

      # All rows for this draw gone.
      assert Repo.aggregate(AddEntriesIdempotency, :count) == 0
    end

    test "failed lock leaves idempotency rows in place (rollback)" do
      api_key = create_api_key()

      # Create a draw with winner_count > entry_count so lock fails.
      draw =
        Draw
        |> Ash.Changeset.for_create(:create, %{winner_count: 5}, actor: api_key)
        |> Ash.create!()

      draw =
        draw
        |> Ash.Changeset.for_update(
          :add_entries,
          %{entries: [%{"weight" => 1}], client_ref: Ash.UUID.generate()},
          actor: api_key
        )
        |> Ash.update!()

      assert Repo.aggregate(AddEntriesIdempotency, :count) == 1

      # Lock will fail (entries < winner_count). The transaction must
      # roll back. Idempotency rows stay.
      assert {:error, %Ash.Error.Invalid{}} =
               draw
               |> Ash.Changeset.for_update(:lock, %{}, actor: api_key)
               |> Ash.update()

      assert Repo.aggregate(AddEntriesIdempotency, :count) == 1
    end
  end

  describe "receipt invariance" do
    test "lock receipt unchanged + payload contains no idempotency keys after table wipe" do
      # Goal-3 / receipt-invariance: idempotency table is operational
      # only. Wiping it must not change a single bit of any signed
      # artefact. Lock receipt parallel to the execution-receipt test
      # below; together they cover both signed surfaces.
      api_key = create_api_key()
      WallopCore.TestHelpers.ensure_infrastructure_key()

      draw = create_draw(api_key, %{winner_count: 1})

      receipt = WallopCore.Resources.OperatorReceipt |> Ash.read_first!(authorize?: false)
      original_signature = receipt.signature
      original_payload = receipt.payload_jcs

      # Forensic check: the payload itself must not contain any idempotency
      # field names. A future refactor that piped one in would fail here.
      payload_str = receipt.payload_jcs

      for forbidden <- ["client_ref", "client_ref_digest", "payload_digest"] do
        refute String.contains?(payload_str, forbidden),
               "lock receipt payload contains '#{forbidden}' — receipt invariance broken"
      end

      # Wipe ALL idempotency rows (might already be empty post-lock,
      # but force the issue).
      Repo.delete_all(AddEntriesIdempotency)

      # Re-fetch the receipt and assert nothing about it changed.
      reloaded = WallopCore.Resources.OperatorReceipt |> Ash.read_first!(authorize?: false)
      assert reloaded.signature == original_signature
      assert reloaded.payload_jcs == original_payload
      assert reloaded.draw_id == draw.id
    end

    test "execution receipt unchanged + payload contains no idempotency keys after table wipe" do
      # Parallel to the lock-receipt test. The execution receipt is the
      # other signed artefact in the protocol; both must be invariant
      # under idempotency-table mutation. ADR-0012.
      api_key = create_api_key()
      WallopCore.TestHelpers.ensure_infrastructure_key()

      # Full flow: create_draw → execute_draw produces an execution receipt.
      draw = create_draw(api_key, %{winner_count: 1})
      draw = execute_draw(draw, WallopCore.TestHelpers.test_seed(), api_key)

      receipt = WallopCore.Resources.ExecutionReceipt |> Ash.read_first!(authorize?: false)
      original_signature = receipt.signature
      original_payload = receipt.payload_jcs

      payload_str = receipt.payload_jcs

      for forbidden <- ["client_ref", "client_ref_digest", "payload_digest"] do
        refute String.contains?(payload_str, forbidden),
               "execution receipt payload contains '#{forbidden}' — receipt invariance broken"
      end

      Repo.delete_all(AddEntriesIdempotency)

      reloaded = WallopCore.Resources.ExecutionReceipt |> Ash.read_first!(authorize?: false)
      assert reloaded.signature == original_signature
      assert reloaded.payload_jcs == original_payload
      assert reloaded.draw_id == draw.id
    end
  end
end
