defmodule WallopCore.Protocol.Tag do
  @moduledoc """
  The receipt rules an entropy tag supplies to lock receipt schema 6 and
  execution receipt schema 5. Each tag is frozen: changing a rule needs a
  new tag.
  """

  @doc "The tag string signed as `entropy_composition`."
  @callback tag() :: String.t()

  @doc "The fallback reason this tag signs when its second source is absent."
  @callback fallback_reason() :: String.t()

  @doc "The sorted lock receipt keys under this tag."
  @callback lock_keys() :: [String.t()]

  @doc "The sorted execution receipt keys under this tag."
  @callback exec_keys() :: [String.t()]

  @doc "Extra lock fields this tag adds; string keys only, never a base key."
  @callback lock_fields(map()) :: map()

  @doc "Extra execution fields this tag adds; string keys only, never a base key."
  @callback exec_fields(map()) :: map()

  @doc "Raises `ArgumentError` unless the lock input satisfies this tag."
  @callback validate_lock!(map()) :: :ok

  @doc "Raises `ArgumentError` unless the execution input satisfies this tag."
  @callback validate_exec!(map()) :: :ok
end
