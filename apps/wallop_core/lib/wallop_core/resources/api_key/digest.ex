defmodule WallopCore.Resources.ApiKey.Digest do
  @moduledoc """
  Labelled SHA-256 digest of a raw API key.

  No server secret: every deployment, including consumers embedding
  wallop_core, computes the same digest. Keys carry ~208 random bits, so a
  fast digest can't be inverted or brute-forced.
  """

  @label "wallop/api-key/v1"

  @spec compute(binary()) :: <<_::256>>
  def compute(raw_key) when is_binary(raw_key) do
    :crypto.hash(:sha256, [@label, <<0>>, raw_key])
  end
end
