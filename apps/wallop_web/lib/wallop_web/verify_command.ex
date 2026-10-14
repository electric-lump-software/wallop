defmodule WallopWeb.VerifyCommand do
  @moduledoc """
  Builds the copy-pasteable `wallop-verify --mode attributable` command
  shown on a completed draw's proof page.

  The rule: pre-fill every value that says *what* to verify, never one
  that says *whom to trust* — unless this deployment's keys aren't in
  the verifier's bundled anchors anyway.

  * Identifiers (base URL, operator slug, bundle filename) are always
    filled in. A wrong one makes verification fail, never pass: the pin
    must verify against an anchor the verifier already holds, and the
    operator slug is read from the bundle's lock receipt and checked
    against the pin.

  * Trust anchors (`--infra-key-pin`) depend on
    `config :wallop_web, :verify_block_anchor_mode`:

      * `:bundled` (default) — omit `--infra-key-pin`. The verifier's
        compiled-in anchors are the independent root. A server that
        supplied its own anchor next to its own bundle would make the
        check circular.
      * `:self` — for deployments whose infrastructure keys are not in
        the released verifier's bundled set (staging, dev, self-hosters).
        Emits one `--infra-key-pin` per key in this instance's full
        infrastructure keyring. The override *replaces* the bundled set,
        and execution receipts resolve against it too, so the current
        key alone would fail any draw executed before a rotation.

  The base URL comes from the endpoint's configured URL, never from the
  request's Host header.

  None of this makes the page a trust root: a page that can be tampered
  with can tamper with its own instructions. See spec §4.2.4.
  """

  require Ash.Query

  alias WallopCore.Resources.InfrastructureSigningKey

  @type t :: %{mode: :bundled | :self, lines: [String.t()]}

  @doc """
  Returns the command for a draw, or `nil` when the draw has no operator
  (attributable mode needs an operator keyring pin).
  """
  @spec build(String.t(), String.t() | atom() | nil) :: t() | nil
  def build(_draw_id, nil), do: nil

  def build(draw_id, operator_slug) do
    mode = Application.get_env(:wallop_web, :verify_block_anchor_mode, :bundled)
    base_url = WallopWeb.Endpoint.url()

    lines =
      [
        "wallop-verify --mode attributable",
        "--wallop-base-url #{base_url}",
        "--pin-from-url #{base_url}/operator/#{operator_slug}/keyring-pin.json"
      ] ++ infra_key_pin_lines(mode) ++ ["#{draw_id}.json"]

    %{mode: mode, lines: lines}
  end

  defp infra_key_pin_lines(:bundled), do: []

  defp infra_key_pin_lines(:self) do
    InfrastructureSigningKey
    |> Ash.Query.sort(valid_from: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn k -> "--infra-key-pin '#{anchor_record_json(k)}'" end)
  end

  # `inserted_at` must be byte-identical to what `/infrastructure/keys`
  # publishes: the verifier's temporal-binding check compares it against
  # the pin's `published_at`. `revoked_at` is always null because the
  # infrastructure keyring has no revocation column; if it gains one, emit
  # it here too (the test compares against `/infrastructure/keys`).
  defp anchor_record_json(key) do
    Jason.encode!(
      Jason.OrderedObject.new(
        key_id: key.key_id,
        public_key_hex: Base.encode16(key.public_key, case: :lower),
        inserted_at: key.inserted_at,
        revoked_at: nil
      )
    )
  end
end
