defmodule WallopCore.Entropy.PollLogTest do
  use ExUnit.Case, async: true

  alias WallopCore.Entropy.PollLog

  @sentinel "SENTINEL-KEY-0f9e8d7c"

  test "atoms and {atom, integer} pass unchanged" do
    for t <- [:missing_hour, :no_api_key, :daily_cap, {:unexpected_status, 503}, {:x, -1}] do
      assert PollLog.term(t) == t
    end
  end

  test "any other tuple is cut to its leading atom" do
    assert PollLog.term({:transport, :timeout}) == :transport
    assert PollLog.term({:missing, :t}) == :missing
    assert PollLog.term({:x, @sentinel}) == :x
    assert PollLog.term({:x, 1, @sentinel}) == :x
    assert PollLog.term({:x, %{key: @sentinel}}) == :x
  end

  test "anything else is :other" do
    for t <- [
          @sentinel,
          {@sentinel, 1},
          {},
          [@sentinel],
          %{key: @sentinel},
          %RuntimeError{message: @sentinel},
          URI.parse("https://example.org/?apikey=#{@sentinel}"),
          1.5,
          self()
        ] do
      assert PollLog.term(t) == :other, inspect(t)
    end
  end

  test "a sentinel key never survives, however it is wrapped" do
    terms = [
      @sentinel,
      {:error, @sentinel},
      {:transport, {:header, @sentinel}},
      {:x, [@sentinel]},
      %{body: @sentinel},
      {%{body: @sentinel}, 1}
    ]

    for t <- terms, do: refute(inspect(PollLog.term(t)) =~ "SENTINEL")
  end
end
