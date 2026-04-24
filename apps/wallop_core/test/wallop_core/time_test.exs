defmodule WallopCore.TimeTest do
  use ExUnit.Case, async: true

  alias WallopCore.Time, as: WTime

  describe "to_rfc3339_usec/1" do
    test "pads zero-precision DateTime to 6 fractional digits" do
      dt = %DateTime{
        year: 2026,
        month: 4,
        day: 23,
        hour: 12,
        minute: 34,
        second: 56,
        microsecond: {0, 0},
        time_zone: "Etc/UTC",
        zone_abbr: "UTC",
        utc_offset: 0,
        std_offset: 0
      }

      assert WTime.to_rfc3339_usec(dt) == "2026-04-23T12:34:56.000000Z"
    end

    test "pads millisecond-precision DateTime to 6 fractional digits" do
      {:ok, dt, 0} = DateTime.from_iso8601("2026-04-23T12:34:56.123Z")
      assert WTime.to_rfc3339_usec(dt) == "2026-04-23T12:34:56.123000Z"
    end

    test "preserves microsecond-precision DateTime" do
      {:ok, dt, 0} = DateTime.from_iso8601("2026-04-23T12:34:56.123456Z")
      assert WTime.to_rfc3339_usec(dt) == "2026-04-23T12:34:56.123456Z"
    end

    test "truncates sub-microsecond precision (should never occur but be safe)" do
      dt = %DateTime{
        year: 2026,
        month: 4,
        day: 23,
        hour: 12,
        minute: 34,
        second: 56,
        microsecond: {123_456, 6},
        time_zone: "Etc/UTC",
        zone_abbr: "UTC",
        utc_offset: 0,
        std_offset: 0
      }

      assert WTime.to_rfc3339_usec(dt) == "2026-04-23T12:34:56.123456Z"
    end

    test "always emits exactly 6 fractional digits + Z suffix" do
      dt = DateTime.utc_now()
      result = WTime.to_rfc3339_usec(dt)

      assert Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/, result)
    end

    test "raises on non-UTC DateTime" do
      dt = %DateTime{
        year: 2026,
        month: 4,
        day: 23,
        hour: 13,
        minute: 34,
        second: 56,
        microsecond: {0, 6},
        time_zone: "Europe/London",
        zone_abbr: "BST",
        utc_offset: 0,
        std_offset: 3600
      }

      assert_raise ArgumentError, ~r/non-UTC/, fn ->
        WTime.to_rfc3339_usec(dt)
      end
    end
  end

  describe "maybe_to_rfc3339_usec/1" do
    test "passes nil through" do
      assert WTime.maybe_to_rfc3339_usec(nil) == nil
    end

    test "formats a DateTime" do
      {:ok, dt, 0} = DateTime.from_iso8601("2026-04-23T12:34:56Z")
      assert WTime.maybe_to_rfc3339_usec(dt) == "2026-04-23T12:34:56.000000Z"
    end
  end

  describe "validate_rfc3339_usec/1" do
    test "accepts canonical form" do
      assert WTime.validate_rfc3339_usec("2026-04-23T12:34:56.123456Z") == :ok
    end

    test "accepts nil" do
      assert WTime.validate_rfc3339_usec(nil) == :ok
    end

    test "rejects 3-digit fractional" do
      assert {:error, _} = WTime.validate_rfc3339_usec("2026-04-23T12:34:56.123Z")
    end

    test "rejects no fractional" do
      assert {:error, _} = WTime.validate_rfc3339_usec("2026-04-23T12:34:56Z")
    end

    test "rejects +00:00 suffix" do
      assert {:error, _} = WTime.validate_rfc3339_usec("2026-04-23T12:34:56.123456+00:00")
    end

    test "rejects non-UTC offset" do
      assert {:error, _} = WTime.validate_rfc3339_usec("2026-04-23T12:34:56.123456+01:00")
    end

    test "rejects 7-digit fractional" do
      assert {:error, _} = WTime.validate_rfc3339_usec("2026-04-23T12:34:56.1234567Z")
    end

    test "rejects non-string, non-nil input" do
      assert {:error, _} = WTime.validate_rfc3339_usec(:not_a_string)
      assert {:error, _} = WTime.validate_rfc3339_usec(1234)
    end

    test "round-trips to_rfc3339_usec output" do
      dt = DateTime.utc_now()
      assert WTime.validate_rfc3339_usec(WTime.to_rfc3339_usec(dt)) == :ok
    end
  end
end
