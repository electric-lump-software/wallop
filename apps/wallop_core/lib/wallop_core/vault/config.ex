defmodule WallopCore.Vault.Config do
  @moduledoc """
  Cloak cipher-list builder for `WallopCore.Vault`. Supports dual-key
  rotation per ADR-0013.

  ## How rotation works

  Each Cloak cipher has a `:tag` that is prefixed onto every ciphertext
  at encrypt time. Cloak inspects the tag prefix on decrypt to route
  the operation to the right cipher. The tag is therefore the
  routing label that distinguishes "old key rows" from "new key rows"
  during a rotation overlap window.

  Two tag constants are pinned here:

  - `@current_tag` — the tag attached to every new encrypted write.
    Used by the `default` cipher.
  - `@previous_tag` — the tag attached to rows encrypted under the
    previous master key. Used by the `retired` cipher when
    `VAULT_KEY_OLD` is supplied.

  Cloak rejects a configuration where two ciphers share the same tag
  (ambiguous routing). `build_ciphers/2` enforces this at config time.

  ## Bumping tag versions

  Bumping `@current_tag` is the load-bearing code change of a
  rotation: it tells Cloak "new writes go to a new tag, previously-
  written rows must be decrypted under the OLD cipher." The procedure
  is documented in `spec/runbooks/vault-key-rotation.md` (added in
  Wave B). The summary:

  1. Bump `@current_tag` to the next generation (e.g. `V1` → `V2`).
     Bump `@previous_tag` in lockstep to what `@current_tag` used to
     be. PR the change.
  2. Set `VAULT_KEY=<new>` and `VAULT_KEY_OLD=<old>` simultaneously.
     Deploy. Both ciphers configured; old rows still decrypt; new
     writes use the new key.
  3. Run `mix wallop.vault.migrate` (Wave B) to re-encrypt all rows
     to the new tag.
  4. Run `mix wallop.vault.verify_rotation` (this PR) — refuses to
     declare success while any row still carries the previous tag.
  5. Drop `VAULT_KEY_OLD` from the environment. Redeploy.

  ## What this module is NOT

  - **Not a migration task.** Building a cipher list is config-time;
    re-encrypting rows is `mix wallop.vault.migrate` (Wave B).
  - **Not a rotation trigger.** Setting `VAULT_KEY_OLD` makes the
    dual-cipher configuration *available*; the rotation procedure
    itself is an operator-controlled multi-step sequence.

  ## Production-unaffected guarantee

  When `VAULT_KEY_OLD` is unset (current production state), this
  module returns the exact single-cipher list that `runtime.exs`
  previously hardcoded. No tag change, no decrypt-path change, no
  observable difference in production behaviour. Adding this module
  is preparation, not migration.
  """

  # Current generation: every new encrypted write is tagged with this.
  # Bump on rotation. Single source of truth.
  #
  # Production is currently V1; existing rows carry this tag.
  @current_tag "AES.GCM.V1"

  # Previous generation: the tag attached to rows encrypted under the
  # previous master key. Only used when `VAULT_KEY_OLD` is supplied
  # (i.e. during a rotation overlap window); ignored otherwise.
  #
  # Production is currently V1; there is NO prior rotation yet, so V0
  # has no rows in the database. This value becomes meaningful when
  # the first rotation bumps current to V2 and previous to V1.
  @previous_tag "AES.GCM.V0"

  @doc "Current cipher tag. New writes use this."
  @spec current_tag() :: String.t()
  def current_tag, do: @current_tag

  @doc """
  Previous-generation cipher tag. Rows under the old key carry this
  (after a rotation begins).
  """
  @spec previous_tag() :: String.t()
  def previous_tag, do: @previous_tag

  @doc """
  Build a Cloak cipher list from the supplied master keys.

  When `vault_key_old` is `nil`, returns a single-cipher list
  (current production shape; unchanged behaviour from pre-ADR-0013
  single-key deployments).

  When `vault_key_old` is supplied, returns a two-cipher list:
  `default` for the new key under `current_tag`, `retired` for
  the old key under `previous_tag`. Cloak routes decrypts via
  tag-prefix dispatch automatically.

  Raises `ArgumentError` if:

  - `vault_key_old == vault_key` (no actual rotation; ambiguous)
  - `@current_tag == @previous_tag` (developer forgot to bump on
    rotation; Cloak cannot route)

  All keys MUST be base64-encoded 32-byte AES-256 keys. Raises if
  the base64 decode fails.
  """
  @spec build_ciphers(String.t(), String.t() | nil) :: keyword()
  def build_ciphers(vault_key, vault_key_old \\ nil)

  def build_ciphers(vault_key, nil) when is_binary(vault_key) do
    [
      default:
        {Cloak.Ciphers.AES.GCM,
         tag: @current_tag, key: decode_key!(vault_key, "VAULT_KEY"), iv_length: 12}
    ]
  end

  def build_ciphers(vault_key, vault_key_old)
      when is_binary(vault_key) and is_binary(vault_key_old) do
    if vault_key == vault_key_old do
      raise ArgumentError, """
      VAULT_KEY and VAULT_KEY_OLD are identical.

      Either the rotation did not actually happen, or VAULT_KEY_OLD was
      set to the same value as VAULT_KEY by mistake. Refusing to boot
      with an ambiguous dual-cipher config.
      """
    end

    if @current_tag == @previous_tag do
      raise ArgumentError, """
      WallopCore.Vault.Config @current_tag and @previous_tag are equal.

      Cloak cannot route decrypts when two ciphers share the same tag.
      Bump @current_tag in WallopCore.Vault.Config before introducing
      VAULT_KEY_OLD into the environment. See ADR-0013 §"Cloak dual-
      key rotation".
      """
    end

    # Wave-A placeholder guard. The shipped tag constants are V1/V0 — V1
    # is what production already uses, V0 is a placeholder until a
    # rotation gets declared in code. Configuring dual-key mode without
    # first bumping @current_tag would route legacy V1 rows (encrypted
    # under the REAL key) to :default (also V1, but the operator now
    # believes VAULT_KEY has been rotated to something new). Cloak
    # cannot distinguish, and the failure surfaces as decrypt errors
    # under load. Refuse to boot until @current_tag has been declared
    # past its launch value. Remove this guard at first rotation.
    if @current_tag == "AES.GCM.V1" and @previous_tag == "AES.GCM.V0" do
      raise ArgumentError, """
      VAULT_KEY_OLD is set but WallopCore.Vault.Config still ships the
      Wave-A placeholder tags (current=AES.GCM.V1, previous=AES.GCM.V0).

      Dual-key mode is only meaningful AFTER bumping @current_tag past
      the launch value — otherwise legacy rows and new writes share the
      :default tag, and Cloak has no way to route between them. Bump
      @current_tag (e.g. to AES.GCM.V2) and @previous_tag (to V1) in
      WallopCore.Vault.Config first, ship that as its own change, and
      only then introduce VAULT_KEY_OLD into the environment.

      See spec/runbooks/vault-key-rotation.md.
      """
    end

    [
      default:
        {Cloak.Ciphers.AES.GCM,
         tag: @current_tag, key: decode_key!(vault_key, "VAULT_KEY"), iv_length: 12},
      retired:
        {Cloak.Ciphers.AES.GCM,
         tag: @previous_tag, key: decode_key!(vault_key_old, "VAULT_KEY_OLD"), iv_length: 12}
    ]
  end

  defp decode_key!(value, name) do
    case Base.decode64(value) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        bytes

      {:ok, bytes} ->
        raise ArgumentError, """
        #{name} must decode to 32 bytes (AES-256), got #{byte_size(bytes)} bytes.
        Use `openssl rand -base64 32` to mint a valid key.
        """

      :error ->
        raise ArgumentError, """
        #{name} is not valid base64.
        Use `openssl rand -base64 32` to mint a valid key.
        """
    end
  end
end
