defmodule WallopWeb.ProofPreLockView do
  @moduledoc """
  Build-side allowlist of fields exposed on the public proof page for
  a draw in `:open` status (pre-lock).

  Pre-lock state is operationally sensitive: entries can still be
  added or removed, weight distribution is still in flux, and the
  signed `entry_hash` does not yet exist. Anything an operator hasn't
  publicly committed to is off-limits to the public proof page.

  This struct enumerates **ONLY** the fields the public template is
  permitted to render. A future PR adding a new field to `Draw` cannot
  accidentally leak it to the public proof page because the template
  binds to this struct's shape, not to the raw `Draw` resource.

  ## What's allowlisted

  - `id` — the draw UUID, already public via the URL.
  - `name` — operator-chosen, deliberately public.
  - `status` — pinned to `:open` (the only valid input).
  - `winner_count` — operator-published count.
  - `entry_count` — public progress signal during the open phase.
  - `opened_at` — when the operator opened the draw.
  - `check_url` — operator-supplied redirect for the entry self-check.
  - `operator_sequence` — already public via the operator's draw listing.
  - `operator` — `%{slug, name}` summary, no internal id / tier / api_key.

  ## What's deliberately NOT exposed pre-lock

  - `entry_hash`, `entry_canonical` (don't exist yet — committed at lock).
  - `seed`, `results`, `signing_key_id`, receipts (don't exist yet).
  - `drand_round`, `drand_chain`, `weather_*` (declared at lock).
  - `metadata`, `callback_url`, `api_key_id`, raw `stage_timestamps`
    (operator/internal).
  - Anything new added to `Draw` after this module — it will not appear
    on the proof page until explicitly added here.

  Verifier-side: the `pre_lock_wide_gap_v1` cross-language vector
  pins this allowlist. A wallop_verifier presented with a pre-lock
  draw page MUST reject any field outside this set; vector covers
  the byte-stable rendered envelope.
  """

  defstruct [
    :id,
    :name,
    :status,
    :winner_count,
    :entry_count,
    :opened_at,
    :check_url,
    :operator_sequence,
    :operator
  ]

  @type operator_summary :: %{slug: String.t(), name: String.t()} | nil

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          status: :open,
          winner_count: pos_integer(),
          entry_count: non_neg_integer(),
          opened_at: DateTime.t() | nil,
          check_url: String.t() | nil,
          operator_sequence: pos_integer() | nil,
          operator: operator_summary()
        }

  @doc """
  Build a `ProofPreLockView` from a `Draw` resource, given an
  optional operator summary.

  Raises `ArgumentError` if the draw's status is not `:open`. This
  is a hard structural invariant — callers MUST gate on status before
  invoking. The check is a defence against future code paths that
  forget the gate.
  """
  @spec from_draw(map(), map() | nil) :: t()
  def from_draw(%{status: :open} = draw, operator) do
    %__MODULE__{
      id: draw.id,
      name: Map.get(draw, :name),
      status: :open,
      winner_count: draw.winner_count,
      entry_count: Map.get(draw, :entry_count) || 0,
      opened_at: opened_at(draw),
      check_url: Map.get(draw, :check_url),
      operator_sequence: Map.get(draw, :operator_sequence),
      operator: operator_summary(operator)
    }
  end

  def from_draw(%{status: status}, _operator) do
    raise ArgumentError,
          "ProofPreLockView.from_draw/2 invoked on a non-open draw " <>
            "(status=#{inspect(status)}). Pre-lock view is only valid for :open."
  end

  defp opened_at(%{stage_timestamps: %{"opened_at" => ts}}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp opened_at(%{inserted_at: dt}), do: dt
  defp opened_at(_), do: nil

  defp operator_summary(nil), do: nil

  defp operator_summary(%{slug: slug, name: name}) do
    %{slug: slug, name: name}
  end

  defp operator_summary(_), do: nil
end
