defmodule WallopCore.Drand.QuicknetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias WallopCore.Drand.Quicknet

  test "constants" do
    assert Quicknet.genesis() == 1_692_803_367
    assert Quicknet.period() == 3
    assert Quicknet.max_round_delta() == 201_600
    assert Quicknet.max_round_delta() * Quicknet.period() == 7 * 24 * 3600
  end

  describe "pub_time/1" do
    test "round 1 is published at genesis" do
      assert Quicknet.pub_time(1) == DateTime.from_unix!(1_692_803_367_000_000, :microsecond)
    end

    test "a known round" do
      assert Quicknet.pub_time(33_068_212) == ~U[2026-10-14 20:00:00.000000Z]
    end

    test "refuses rounds below 1 and non-integers" do
      assert_raise FunctionClauseError, fn -> Quicknet.pub_time(0) end
      assert_raise FunctionClauseError, fn -> Quicknet.pub_time(1.0) end
    end
  end

  describe "round_at/1" do
    test "inverts pub_time" do
      assert Quicknet.round_at(~U[2026-10-14 20:00:00.000000Z]) == {:ok, 33_068_212}
      assert Quicknet.round_at(Quicknet.pub_time(1)) == {:ok, 1}
    end

    test "refuses sub-second, off-grid and pre-genesis times" do
      assert Quicknet.round_at(~U[2026-10-14 20:00:00.500000Z]) == {:error, :sub_second}
      assert Quicknet.round_at(~U[2026-10-14 20:00:01.000000Z]) == {:error, :not_on_grid}
      assert Quicknet.round_at(~U[2020-01-01 00:00:00.000000Z]) == {:error, :before_genesis}
    end
  end

  describe "round_at_or_after/1" do
    test "on the grid it is the round published then" do
      assert Quicknet.round_at_or_after(~U[2026-10-14 20:00:00.000000Z]) == 33_068_212
    end

    test "between grid points it is the next round" do
      assert Quicknet.round_at_or_after(~U[2026-10-14 20:00:00.000001Z]) == 33_068_213
      assert Quicknet.round_at_or_after(~U[2026-10-14 19:59:58.000000Z]) == 33_068_212
    end

    test "before genesis it is round 1" do
      assert Quicknet.round_at_or_after(~U[2020-01-01 00:00:00.000000Z]) == 1
    end

    property "it is the earliest round published at or after the time" do
      check all(us <- integer(1_692_803_367_000_000..1_900_000_000_000_000)) do
        time = DateTime.from_unix!(us, :microsecond)
        round = Quicknet.round_at_or_after(time)

        assert DateTime.compare(Quicknet.pub_time(round), time) != :lt
        assert round == 1 or DateTime.compare(Quicknet.pub_time(round - 1), time) == :lt
      end
    end
  end
end
