defmodule WallopCore.Attacks.FreqDuplicateKeysTest do
  @moduledoc """
  The Elexon body is stored as `raw` so that it proves the stored value
  ("the stored value must be exactly what the stored Elexon bytes give").
  That only holds if every reader gets the same value from the bytes.

  With a key twice in one object, readers disagree: a last-wins reader and
  a first-wins reader get different windows from the same bytes, and a
  strict reader refuses them. So a body such as
  `{"data":[], "data":[8 good rows]}`, or a row with two `frequency` keys,
  must be refused before anything is stored. The decoder
  (`FreqGrammar.decode/1`, shared with Land Obs) refuses a duplicate key at
  any level with `{:error, :duplicate_key}`; both shapes are in
  `freq-window-v1.json`.
  """
  use ExUnit.Case, async: true

  import WallopCore.TestHelpers, only: [elexon_body: 2]

  alias WallopCore.Frequency.FreqGrammar

  @t ~U[2026-10-14 19:54:00.000000Z]
  @value "50012;50018;50012;49983;49980;49953;49912;49883"

  defp window(body) do
    case FreqGrammar.decode(body) do
      {:ok, %{"data" => rows}} when is_list(rows) -> FreqGrammar.window_from_rows(rows, @t)
      other -> {:refused, other}
    end
  end

  test "control: the plain body gives the window" do
    assert window(elexon_body(@t, @value)) == {:ok, @value}
  end

  test "a duplicate top-level data key is refused, not read last-wins" do
    good = elexon_body(@t, @value)
    body = String.replace(good, ~s({"data":[), ~s({"data":[],"data":[), global: false)
    refute body == good

    assert window(body) == {:refused, {:error, :duplicate_key}}
  end

  test "a row with two frequency keys is refused, not read last-wins" do
    good = elexon_body(@t, @value)

    body =
      String.replace(good, ~s("frequency":49.883), ~s("frequency":50.999,"frequency":49.883),
        global: false
      )

    refute body == good

    assert window(body) == {:refused, {:error, :duplicate_key}}
  end
end
