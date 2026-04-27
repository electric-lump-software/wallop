defmodule WallopCore.Resources.Draw.Changes.SignAndStoreExecutionReceipt do
  @moduledoc """
  Signs an execution receipt at draw completion time and inserts it into
  `execution_receipts` in the same transaction.

  Mirrors `SignAndStoreReceipt` in structure but uses the **wallop
  infrastructure key** (not the operator's key) and commits to the
  execution output (entropy values, seed, results) rather than the
  commitment input (entries, lock time).

  The two receipts together give a verifier everything they need to
  confirm both halves of the commit-reveal protocol using only signed
  bytes.

  Fails hard if the draw has no operator — a draw without an operator
  cannot participate in the proof protocol.

  If anything fails — infra key resolution, decryption, signing, insert
  — the draw completion rolls back. The draw stays in its pre-completion
  state and the entropy worker retries.
  """
  use Ash.Resource.Change

  alias WallopCore.Log
  alias WallopCore.Protocol
  alias WallopCore.Resources.{ExecutionReceipt, InfrastructureSigningKey, OperatorReceipt}
  alias WallopCore.Vault

  require Ash.Query
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, draw ->
      case draw.operator_id do
        nil -> {:error, "draw has no operator — cannot sign execution receipt"}
        _operator_id -> sign_and_store(draw)
      end
    end)
  end

  defp sign_and_store(draw) do
    with {:ok, lock_receipt} <- load_lock_receipt(draw.id),
         {:ok, infra_key} <- load_current_infra_key(),
         {:ok, private_key} <- decrypt_private_key(infra_key.private_key),
         :ok <-
           Protocol.assert_key_consistency(
             infra_key.public_key,
             private_key,
             infra_key.key_id
           ),
         {:ok, operator_slug} <- load_operator_slug(draw.operator_id),
         {:ok, canonical_results} <- validate_results(draw.results) do
      lock_receipt_hash = hash_lock_receipt(lock_receipt.payload_jcs)

      payload =
        Protocol.build_execution_receipt_payload(%{
          draw_id: draw.id,
          operator_id: draw.operator_id,
          operator_slug: operator_slug,
          sequence: draw.operator_sequence,
          lock_receipt_hash: lock_receipt_hash,
          entry_hash: draw.entry_hash,
          drand_chain: draw.drand_chain,
          drand_round: draw.drand_round,
          drand_randomness: draw.drand_randomness,
          drand_signature: draw.drand_signature,
          weather_station: draw.weather_station,
          weather_observation_time: draw.weather_observation_time,
          weather_value: draw.weather_value,
          weather_fallback_reason: draw.weather_fallback_reason,
          wallop_core_version: app_version!(:wallop_core),
          fair_pick_version: app_version!(:fair_pick),
          seed: draw.seed,
          results: canonical_results,
          executed_at: draw.executed_at,
          signing_key_id: infra_key.key_id
        })

      signature = Protocol.sign_receipt(payload, private_key)

      case insert_execution_receipt(draw, lock_receipt_hash, payload, signature, infra_key.key_id) do
        {:ok, _receipt} -> {:ok, draw}
        {:error, error} -> {:error, error}
      end
    else
      {:error, :no_lock_receipt} ->
        Logger.error(
          "SignAndStoreExecutionReceipt: no lock receipt for draw #{Log.redact_id(draw.id)}"
        )

        {:error, "draw has no lock receipt — cannot chain execution receipt"}

      {:error, :no_infra_key} ->
        Logger.error("SignAndStoreExecutionReceipt: no infrastructure signing key found")
        {:error, "no infrastructure signing key — run mix wallop.bootstrap_infrastructure_key"}

      {:error, :operator_not_found} ->
        Logger.error(
          "SignAndStoreExecutionReceipt: operator not found for draw #{Log.redact_id(draw.id)}"
        )

        {:error, "operator not found — cannot sign execution receipt"}

      {:error, :no_results} ->
        Logger.error(
          "SignAndStoreExecutionReceipt: draw #{Log.redact_id(draw.id)} has no results"
        )

        {:error, "draw has no results — cannot sign execution receipt"}

      {:error, reason} ->
        Logger.error(
          "SignAndStoreExecutionReceipt: failed for draw #{Log.redact_id(draw.id)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp load_lock_receipt(draw_id) do
    OperatorReceipt
    |> Ash.Query.filter(draw_id == ^draw_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %OperatorReceipt{} = r} -> {:ok, r}
      {:ok, nil} -> {:error, :no_lock_receipt}
      {:error, e} -> {:error, e}
    end
  end

  defp load_current_infra_key do
    now = DateTime.utc_now()

    InfrastructureSigningKey
    |> Ash.Query.filter(valid_from <= ^now)
    |> Ash.Query.sort(valid_from: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [key]} -> {:ok, key}
      {:ok, []} -> {:error, :no_infra_key}
      {:error, e} -> {:error, e}
    end
  end

  defp decrypt_private_key(encrypted) do
    case Vault.decrypt(encrypted) do
      {:ok, raw} -> {:ok, raw}
      {:error, e} -> {:error, e}
    end
  end

  defp hash_lock_receipt(payload_jcs) when is_binary(payload_jcs) do
    :crypto.hash(:sha256, payload_jcs) |> Base.encode16(case: :lower)
  end

  defp load_operator_slug(operator_id) do
    case Ash.get(WallopCore.Resources.Operator, operator_id, authorize?: false) do
      {:ok, op} -> {:ok, to_string(op.slug)}
      {:error, _} -> {:error, :operator_not_found}
    end
  end

  defp validate_results(nil), do: {:error, :no_results}
  defp validate_results([]), do: {:error, :no_results}

  defp validate_results(results) when is_list(results) do
    canonical =
      results
      |> Enum.sort_by(fn r -> r["position"] end)
      |> Enum.map(fn r -> r["entry_id"] end)

    {:ok, canonical}
  end

  defp insert_execution_receipt(draw, lock_receipt_hash, payload, signature, key_id) do
    ExecutionReceipt
    |> Ash.Changeset.for_create(:create, %{
      draw_id: draw.id,
      operator_id: draw.operator_id,
      sequence: draw.operator_sequence,
      lock_receipt_hash: lock_receipt_hash,
      payload_jcs: payload,
      signature: signature,
      signing_key_id: key_id
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
