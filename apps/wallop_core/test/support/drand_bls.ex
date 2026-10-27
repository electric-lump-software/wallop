defmodule WallopCore.Test.DrandBls do
  @moduledoc """
  The BLS check `DrandClient` uses in tests (set in `config/test.exs`).

  Most observation-weather tests need a drand beacon for a round near
  "now", which no fixture can sign. They serve quicknet round 33068212's
  real signature for whatever round they ask for (`stand_in_signature/0`),
  and this accepts that one signature at any round. Every other signature
  goes to the real check (`WallopCore.Drand.Bls`), so forged, malformed and
  other-key signatures are refused exactly as in production, and the
  fixture rounds verify for real.
  """

  alias WallopCore.Drand.Bls

  @stand_in "b6541e41bb68ff318e8bd74b9f6e168ae6424476c432241420c38427df58c6ef33fe009ce202a7101120ab481702fddf"

  @doc "The one signature accepted at any round."
  @spec stand_in_signature() :: String.t()
  def stand_in_signature, do: @stand_in

  @spec verify_quicknet(term(), term()) :: boolean()
  def verify_quicknet(round, @stand_in) when is_integer(round), do: true
  def verify_quicknet(round, signature_hex), do: Bls.verify_quicknet(round, signature_hex)
end
