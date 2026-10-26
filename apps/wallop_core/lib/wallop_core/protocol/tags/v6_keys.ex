defmodule WallopCore.Protocol.Tags.V6Keys do
  @moduledoc """
  The key sets of lock receipt schema 6 and execution receipt schema 5,
  shared by both of their entropy tags (Met Office Land Observations, GB
  grid frequency). Sorted bytewise: the SQL twins `wallop_v6_lock_keys()`
  and `wallop_v6_exec_keys()` are compared with
  array_agg(k ORDER BY k COLLATE "C").
  """

  @lock_keys ~w(commitment_hash drand_chain drand_round draw_id entropy_composition
                entry_hash fair_pick_version freq_start jcs_version locked_at
                operator_id operator_slug schema_version sequence
                signature_algorithm signing_key_id wallop_core_version
                weather_station weather_time winner_count)

  @exec_keys ~w(drand_chain drand_randomness drand_round drand_signature
                drand_signature_algorithm draw_id entropy_composition entry_hash executed_at
                fair_pick_version freq_fallback_reason freq_value jcs_version
                lock_receipt_hash merkle_algorithm operator_id operator_slug results
                schema_version seed sequence signature_algorithm signing_key_id
                wallop_core_version weather_fallback_reason weather_observation_time
                weather_station weather_value)

  @doc "Every key of a lock receipt schema 6, sorted."
  @spec lock_keys() :: [String.t()]
  def lock_keys, do: @lock_keys

  @doc "Every key of an execution receipt schema 5, sorted."
  @spec exec_keys() :: [String.t()]
  def exec_keys, do: @exec_keys
end
