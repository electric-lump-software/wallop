defmodule WallopCore.Time do
  @moduledoc """
  RFC 3339 timestamp formatting with guaranteed microsecond precision.

  Every timestamp inside a signed receipt payload MUST serialise as
  `YYYY-MM-DDTHH:MM:SS.ffffffZ` — exactly 6 fractional digits, explicit
  `Z` suffix, never `+00:00`. Anything else is a cross-implementation
  parity bug (one producer emits `.000Z`, another emits `.000000Z`,
  signatures diverge).

  `DateTime.to_iso8601/1` in the standard library emits 0, 3, or 6
  fractional digits depending on the `DateTime`'s `:microsecond`
  tuple — `{n, 0}` gets no fractional, `{n, 3}` gets milliseconds,
  `{n, 6}` gets microseconds. Since DateTimes reach this code via
  Postgres round-trips, `:utc_now/0`, test fixtures, and HTTP parsing,
  their precision markers vary. This module is the one place that
  normalises: pad to 6 digits, coerce `+00:00` → `Z`.

  Pinned in the 1.x stability contract at `spec/protocol.md` §4.2.1.
  """

  @pattern ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/

  @doc """
  Returns the canonical RFC 3339 UTC string with exactly 6 fractional
  digits and a `Z` suffix. Raises on non-UTC input.
  """
  @spec to_rfc3339_usec(DateTime.t()) :: String.t()
  def to_rfc3339_usec(%DateTime{time_zone: "Etc/UTC"} = dt) do
    dt
    |> DateTime.truncate(:microsecond)
    |> Map.update!(:microsecond, fn {value, _precision} -> {value, 6} end)
    |> DateTime.to_iso8601()
    |> normalise_suffix()
  end

  def to_rfc3339_usec(%DateTime{} = dt) do
    raise ArgumentError,
          "refusing to serialise non-UTC DateTime into signed payload: " <>
            inspect(dt)
  end

  @doc """
  Same as `to_rfc3339_usec/1` but passes `nil` through. Used for
  nullable timestamp fields on signed payloads (e.g. `weather_time` on
  a caller-seed draw).
  """
  @spec maybe_to_rfc3339_usec(DateTime.t() | nil) :: String.t() | nil
  def maybe_to_rfc3339_usec(nil), do: nil
  def maybe_to_rfc3339_usec(%DateTime{} = dt), do: to_rfc3339_usec(dt)

  @doc """
  Validates a serialised timestamp string matches the canonical format.
  Returns `:ok` or `{:error, reason}`.

  Used at receipt-build time (defence-in-depth against a call site that
  bypasses `to_rfc3339_usec/1`) and at verifier ingest (rejects
  malformed timestamps from untrusted payloads).
  """
  @spec validate_rfc3339_usec(term()) :: :ok | {:error, String.t()}
  def validate_rfc3339_usec(value) when is_binary(value) do
    if Regex.match?(@pattern, value) do
      :ok
    else
      {:error,
       "timestamp must match YYYY-MM-DDTHH:MM:SS.ffffffZ (6 fractional digits, Z suffix); got: " <>
         inspect(value)}
    end
  end

  def validate_rfc3339_usec(nil), do: :ok

  def validate_rfc3339_usec(other),
    do: {:error, "timestamp must be a string or nil; got: #{inspect(other)}"}

  # DateTime.to_iso8601/1 on a UTC DateTime already emits `Z`, but
  # be defensive — normalise any `+00:00` suffix a future OTP version
  # might switch to.
  defp normalise_suffix(iso) do
    cond do
      String.ends_with?(iso, "Z") -> iso
      String.ends_with?(iso, "+00:00") -> String.replace_suffix(iso, "+00:00", "Z")
      true -> raise ArgumentError, "unexpected ISO-8601 suffix in: #{inspect(iso)}"
    end
  end
end
