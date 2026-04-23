defmodule WallopCore.Entropy.WeatherFallback do
  @moduledoc """
  Classifies raw weather-client errors into the frozen enum used on the
  execution receipt's `weather_fallback_reason` field.

  The classifier is a total, pure function. Any weather error — regardless
  of source or tuple shape — maps to one of four values. A fifth value
  would require a receipt schema bump, so this function must never return
  a novel reason.

  ## Enum values

  - `:station_down` — the configured weather station is returning no data,
    or reports itself as offline. Use when the identity of the failure is
    clearly "this specific station isn't there right now".
  - `:stale` — an observation was returned but it is older than the
    acceptable window. The station is up; the data is not current.
  - `:unreachable` — catch-all for everything else: transient network
    failures, 5xx errors, 4xx errors (including auth), unexpected shapes.
    "Weather unavailable, reason not worth decomposing further."
  - `nil` — the weather path did not fall back; this receipt was built
    with full drand + weather entropy.

  Decomposing `:unreachable` further is a v2.0.0 conversation.
  """

  @type reason :: :station_down | :stale | :unreachable | nil

  @doc """
  Classify a raw weather-fetch error into the enum.

  `nil` in → `nil` out (no fallback happened).
  Anything else → one of the three atom values.
  """
  @spec classify(term()) :: reason()
  def classify(nil), do: nil
  def classify(:not_found), do: :station_down
  def classify(:stale_observation), do: :stale

  def classify({:unexpected_status, status}) when is_integer(status) and status in 500..599,
    do: :unreachable

  def classify({:unexpected_status, status}) when is_integer(status) and status in 400..499,
    do: :unreachable

  def classify({:unexpected_status, _}), do: :unreachable
  def classify(_), do: :unreachable

  @doc """
  Convert the enum atom to the string that appears in the JCS-encoded
  receipt payload. `nil` remains `nil`.
  """
  @spec to_string(reason()) :: String.t() | nil
  def to_string(nil), do: nil
  def to_string(:station_down), do: "station_down"
  def to_string(:stale), do: "stale"
  def to_string(:unreachable), do: "unreachable"
end
