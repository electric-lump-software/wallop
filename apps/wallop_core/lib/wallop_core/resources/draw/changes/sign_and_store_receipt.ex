defmodule WallopCore.Resources.Draw.Changes.SignAndStoreReceipt do
  @moduledoc """
  Signs an operator commitment receipt at draw lock time and inserts it into
  `operator_receipts` in the same transaction.

  If anything fails — missing operator, current signing key resolution,
  private key decryption, signing, receipt insert — the entire lock action
  rolls back via Ash's before_action error path. The draw stays `:open`
  and no sequence is burned.

  With `version: "6"` it signs lock schema 6 (`Protocol.build_v6_lock_payload/1`)
  for an observation-weather draw. `locked_at` is taken once, after the
  draw row is locked, and that one value is checked against the draw's
  latest lock time, signed, stored in the receipt's `locked_at` column and
  recorded as the draw's `locked_at` stage timestamp. A late value is
  refused here (on `draw_at` when it was sent, with `latest_lock_at`), so the builder never
  sees one; if the builder raises anyway, the lock transaction rolls back.
  The database checks the same stored value again when the receipt is
  inserted, after the lock UPDATE in the same transaction.

  Without `version` it signs lock schema 5, exactly as before schema 6.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias WallopCore.Protocol
  alias WallopCore.Resources.{OperatorReceipt, OperatorSigningKey}
  alias WallopCore.Vault
  alias WallopCore.Weather.Schedule

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &sign(&1, opts[:version]))
  end

  defp sign(changeset, version) do
    draw = changeset.data

    case draw.operator_id do
      nil ->
        Ash.Changeset.add_error(changeset,
          field: :operator_id,
          message: "draw has no operator — cannot sign lock receipt"
        )

      operator_id ->
        do_sign(changeset, draw, operator_id, version)
    end
  end

  defp do_sign(changeset, draw, operator_id, version) do
    locked_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case lock_time_error(version, locked_at, changeset) do
      nil -> sign_at(changeset, draw, operator_id, version, locked_at)
      error -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp sign_at(changeset, draw, operator_id, version, locked_at) do
    with {:ok, operator} <- load_operator(operator_id),
         {:ok, signing_key} <- load_current_signing_key(operator_id, locked_at),
         {:ok, private_key} <- decrypt_private_key(signing_key.private_key),
         :ok <-
           Protocol.assert_key_consistency(
             signing_key.public_key,
             private_key,
             signing_key.key_id
           ),
         commitment_hash <- Ash.Changeset.get_attribute(changeset, :entry_hash) do
      input = %{
        operator_id: operator.id,
        operator_slug: operator.slug,
        sequence: draw.operator_sequence,
        draw_id: draw.id,
        commitment_hash: commitment_hash,
        entry_hash: commitment_hash,
        locked_at: locked_at,
        signing_key_id: signing_key.key_id,
        winner_count: draw.winner_count,
        drand_chain: Ash.Changeset.get_attribute(changeset, :drand_chain),
        drand_round: Ash.Changeset.get_attribute(changeset, :drand_round),
        weather_station: Ash.Changeset.get_attribute(changeset, :weather_station),
        weather_time: Ash.Changeset.get_attribute(changeset, :weather_time),
        wallop_core_version: app_version!(:wallop_core),
        fair_pick_version: app_version!(:fair_pick)
      }

      payload = build_payload(version, input, changeset)
      signature = Protocol.sign_receipt(payload, private_key)

      changeset
      |> record_locked_at(version, locked_at)
      |> Ash.Changeset.after_action(fn _cs, draw ->
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

  # The refusal points at draw_at only when the operator sent one; a lock
  # on the default draw time is refused at the action level.
  defp lock_time_error("6", locked_at, changeset) do
    field = if Ash.Changeset.get_argument(changeset, :draw_at), do: :draw_at

    v6_lock_time_error(
      locked_at,
      Ash.Changeset.get_attribute(changeset, :weather_time),
      field
    )
  end

  defp lock_time_error(nil, _locked_at, _changeset), do: nil

  @doc false
  # Lock schema 6: a lock at `locked_at` must be no later than the draw's
  # latest lock time (weather_time - 46 minutes). nil when it is in time,
  # else the refusal, on `field` (default `draw_at`; nil for an action-level
  # error) with `latest_lock_at` as a whole-second RFC 3339 string. Used on
  # the signed `locked_at` here and on the request time by the `DrawAt`
  # validation.
  @spec v6_lock_time_error(DateTime.t(), DateTime.t(), :draw_at | nil) :: Exception.t() | nil
  def v6_lock_time_error(locked_at, weather_time, field \\ :draw_at) do
    if Schedule.lock_allowed?(locked_at, weather_time) do
      nil
    else
      InvalidArgument.exception(
        field: field,
        message: "is too late: this draw must be locked by %{latest_lock_at}",
        vars: [latest_lock_at: whole_second(Schedule.latest_lock_at(weather_time))]
      )
    end
  end

  # weather_time is a whole hour, so latest_lock_at is a whole second.
  defp whole_second(dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp build_payload("6", input, changeset) do
    input
    |> Map.put(
      :entropy_composition,
      Ash.Changeset.get_attribute(changeset, :entropy_composition)
    )
    |> Protocol.build_v6_lock_payload()
  end

  defp build_payload(nil, input, _changeset), do: Protocol.build_receipt_payload(input)

  # Lock schema 6 only: the draw's locked_at stage timestamp is the signed
  # value, not a second reading of the clock.
  defp record_locked_at(changeset, "6", locked_at) do
    stages = Ash.Changeset.get_attribute(changeset, :stage_timestamps) || %{}

    Ash.Changeset.force_change_attribute(
      changeset,
      :stage_timestamps,
      Map.put(stages, "locked_at", WallopCore.Time.to_rfc3339_usec(locked_at))
    )
  end

  defp record_locked_at(changeset, nil, _locked_at), do: changeset

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

  defp app_version!(app) do
    case Application.spec(app, :vsn) do
      nil ->
        raise "#{app} version not available — cannot sign receipt with unknown version"

      vsn ->
        to_string(vsn)
    end
  end
end
