defmodule WallopCore.Log do
  @moduledoc """
  Observability-safe redaction of wallop-internal identifiers (draw UUIDs,
  entry UUIDs, api_key IDs) for `Logger` calls, telemetry attributes, and
  any other log-like side channel.

  Every `*_id` reaching the log stream MUST pass through `redact_id/1` or
  a caller that delegates to it. `spec/protocol.md` §4.3 commits wallop to
  keeping per-entry and per-draw identifiers out of observable side
  channels; the log stream is a side channel, so any raw UUID printed
  there is a violation.

  ## Redaction form

  `HMAC-SHA-256(per-VM salt, id) |> binary_part(0, 5) |> hex`.

  Output is a lowercase 10-hex-character string — 5 bytes / 40 bits of
  per-run cardinality. Birthday collisions become statistically likely
  around 2^20 distinct inputs per salt; wallop's per-run log volume is
  comfortably below that even for entry-dominant loads.

  ## Salt lifecycle

  The salt lives in `:persistent_term` under the key `{__MODULE__, :salt}`.
  It is 32 random bytes generated lazily on first call to `redact_id/1`
  in the current VM. The salt is never persisted to disk or exported to
  telemetry. On every BEAM restart it is regenerated, which is deliberate:
  an attacker who obtains last week's log tape cannot correlate redacted
  IDs against this week's, because the salt that produced those bytes is
  gone.

  Salt generation emits one telemetry event per VM run at
  `[:wallop_core, :log, :salt_generated]` so that salt resets
  mid-run (e.g. a test helper accidentally calling `:persistent_term.erase/1`)
  are visible in metrics rather than silently decohering intra-run log
  correlation.

  ## Why not just truncate the UUID?

  Static first-8-hex truncation is cheaper but produces the same
  redacted form for the same UUID forever, across every log tape, every
  operator, every export. That is exactly the cross-run correlation
  vector §4.3 exists to deny. Static truncation would be a violation,
  not a mitigation.
  """

  @salt_bytes 32
  @output_bytes 5

  @doc """
  Redact a binary identifier for log / telemetry emission.

  Returns a lowercase 10-hex string. Same input → same output within a
  single BEAM run; different across BEAM runs.

  Nil and non-string inputs are tagged defensively rather than crashing,
  because a bad call site should not take the VM down and should not
  leak the raw value either.
  """
  @spec redact_id(term()) :: String.t()
  def redact_id(id) when is_binary(id) do
    :crypto.mac(:hmac, :sha256, salt(), id)
    |> binary_part(0, @output_bytes)
    |> Base.encode16(case: :lower)
  end

  def redact_id(nil), do: "nil"
  def redact_id(_other), do: "<non-string>"

  @doc """
  Redact a list of binary identifiers. Convenience wrapper.
  """
  @spec redact_ids([term()]) :: [String.t()]
  def redact_ids(ids) when is_list(ids), do: Enum.map(ids, &redact_id/1)

  @doc """
  Redact known identifier keys inside a map of telemetry / log
  attributes. The canonical set is the wallop-internal identifier keys
  that appear across workers, controllers, and span builders:

      draw.id, draw_id, entry_id, operator_id, api_key_id,
      infrastructure_key_id, lock_receipt_id, execution_receipt_id

  Any key whose name ends in `.id`, `_id`, or equals `"id"` and whose
  value is a binary is redacted. Non-string values pass through. Keys
  whose names are not in the identifier set pass through unchanged.

  Use this once at the top of a `:telemetry.execute/3` or `Logger.*`
  call site to scrub a whole attrs map without per-key boilerplate.
  """
  @spec span_attrs(map()) :: map()
  def span_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} ->
      if id_key?(key) and is_binary(value) do
        {key, redact_id(value)}
      else
        {key, value}
      end
    end)
  end

  # Matches "id", "*.id", "*_id" (case-sensitive; wallop keys are all
  # lowercase snake_case). Keeps non-ID keys pass-through so a caller
  # can hand in the whole attrs map without filtering first.
  defp id_key?(key) when is_binary(key) do
    key == "id" or
      String.ends_with?(key, "_id") or
      String.ends_with?(key, ".id")
  end

  defp id_key?(key) when is_atom(key), do: id_key?(Atom.to_string(key))
  defp id_key?(_), do: false

  # Fetches the per-VM salt. On first call, generates 32 random bytes,
  # stores in :persistent_term, and emits a telemetry event. Subsequent
  # calls are a single persistent_term lookup — no locks, no race.
  defp salt do
    case :persistent_term.get({__MODULE__, :salt}, :undefined) do
      :undefined ->
        new_salt = :crypto.strong_rand_bytes(@salt_bytes)
        :persistent_term.put({__MODULE__, :salt}, new_salt)

        :telemetry.execute(
          [:wallop_core, :log, :salt_generated],
          %{count: 1},
          %{pid: self()}
        )

        new_salt

      existing ->
        existing
    end
  end
end
