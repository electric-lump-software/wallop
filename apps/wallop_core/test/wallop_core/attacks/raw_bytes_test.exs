defmodule WallopCore.Attacks.RawBytesTest do
  @moduledoc """
  `ElexonFreqClient`, `Windows.store/3` and the Land Obs store promise
  that `raw` is the response body "byte for byte", so the stored bytes prove
  the stored value.

  A plain Ash `:string` trims surrounding whitespace by default. A body
  with a trailing newline (or any leading or trailing whitespace, which JSON
  allows) passed the raw check in `Windows.store/3`, which runs before the
  cast, and was then stored trimmed. A later dispute comparing a hash of
  the body with the source's own record, or a network-captured copy, would
  fail although nothing was tampered with. `raw` on both resources now has
  `trim?: false`.
  """
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Drand.Quicknet
  alias WallopCore.Frequency.{Schedule, Windows}
  alias WallopCore.Weather.{Observations, Stations}
  alias WallopCore.Weather.Schedule, as: WeatherSchedule

  @value "50012;50018;50012;49983;49980;49953;49912;49883"

  test "a frequency window's raw is stored byte for byte, whitespace included" do
    t = aligned_freq_start(-(Schedule.span_seconds() + 60))
    {_op, key} = create_freq_operator()
    round = Quicknet.round_at_or_after(DateTime.add(DateTime.utc_now(), 3600))
    put_freq_awaiting!(open_draw_with_entries(key), t, round)

    body = "\n  " <> elexon_body(t, @value) <> "\r\n"

    assert {:ok, _} = Windows.store(t, @value, body)
    stored = Windows.for_start(t)

    assert stored.raw == body,
           "stored raw differs from the Elexon body: " <>
             "#{byte_size(stored.raw)} bytes stored, #{byte_size(body)} received"
  end

  test "a Land Obs observation's raw is stored byte for byte, whitespace included" do
    {:ok, s} = WeatherSchedule.schedule(WeatherSchedule.default_draw_at(DateTime.utc_now()))
    {_op, key} = create_v6_operator()
    wt = DateTime.utc_now() |> DateTime.add(-5 * 60) |> DateTime.truncate(:second)
    put_v6_awaiting!(open_draw_with_entries(key), wt, s.round)

    body = " \n[]\t\r\n"

    assert {:ok, _} =
             Observations.store(Stations.primary().id, %{
               value: "141;1025;85;2432",
               raw: body,
               observation_time: wt
             })

    assert Observations.for_hour(wt).raw == body
  end
end
