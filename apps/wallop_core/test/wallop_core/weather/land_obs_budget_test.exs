defmodule WallopCore.Weather.LandObsBudgetTest do
  use WallopCore.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WallopCore.DbClock
  alias WallopCore.Repo
  alias WallopCore.Resources.LandObsCallCount
  alias WallopCore.Weather.{LandObsBudget, Schedule}

  setup do
    previous = Application.get_env(:wallop_core, :land_obs_daily_cap)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wallop_core, :land_obs_daily_cap, previous),
        else: Application.delete_env(:wallop_core, :land_obs_daily_cap)
    end)
  end

  defp count(day) do
    %{rows: rows} =
      Repo.query!("SELECT calls FROM land_obs_call_counts WHERE utc_day = $1", [day])

    case rows do
      [[calls]] -> calls
      [] -> 0
    end
  end

  defp today, do: DateTime.to_date(DbClock.now())

  describe "parse_cap!/1" do
    test "unset is the default of 800" do
      assert LandObsBudget.parse_cap!(nil) == 800
      assert LandObsBudget.default_cap() == 800
    end

    test "accepts any whole number from 1 to 900" do
      for v <- [1, 623, 624, 800, 900], do: assert(LandObsBudget.parse_cap!("#{v}") == v)
    end

    test "anything else raises" do
      for v <- ["", "0", "-1", "901", "1000", "800.0", " 800", "800 ", "8e2", "abc", "0x320"] do
        assert_raise ArgumentError,
                     ~r/LAND_OBS_DAILY_CAP must be a whole number from 1 to 900/,
                     fn ->
                       LandObsBudget.parse_cap!(v)
                     end
      end
    end
  end

  describe "runtime.exs" do
    @runtime Path.expand("../../../../../config/runtime.exs", __DIR__)

    defp read_cap(value) do
      previous = System.get_env("LAND_OBS_DAILY_CAP")

      if value,
        do: System.put_env("LAND_OBS_DAILY_CAP", value),
        else: System.delete_env("LAND_OBS_DAILY_CAP")

      try do
        @runtime |> Config.Reader.read!(env: :test) |> get_in([:wallop_core, :land_obs_daily_cap])
      after
        if previous,
          do: System.put_env("LAND_OBS_DAILY_CAP", previous),
          else: System.delete_env("LAND_OBS_DAILY_CAP")
      end
    end

    test "reads LAND_OBS_DAILY_CAP, defaulting to 800, and refuses a bad value at boot" do
      assert File.exists?(@runtime)
      assert read_cap(nil) == 800
      assert read_cap("623") == 623
      assert read_cap("900") == 900

      for bad <- ["0", "901", "lots"] do
        assert_raise ArgumentError, ~r/LAND_OBS_DAILY_CAP/, fn -> read_cap(bad) end
      end
    end
  end

  describe "the full day of polling" do
    test "is 26 polls an hour for 24 hours, from the polling schedule" do
      polls_per_hour =
        div(
          Schedule.fetch_window_seconds() - Schedule.first_poll_after_weather_time_seconds(),
          Schedule.poll_interval_seconds()
        ) + 1

      assert polls_per_hour == 26
      assert LandObsBudget.full_day_calls() == polls_per_hour * 24
      assert LandObsBudget.full_day_calls() == 624
    end

    test "a cap below it gets a boot warning; at or above it, none" do
      assert LandObsBudget.boot_warning(623) =~ "below a full day of polling (624)"
      assert LandObsBudget.boot_warning(1) =~ "observation-weather draws may fall back"

      for cap <- [624, 800, 900], do: assert(LandObsBudget.boot_warning(cap) == nil)
    end

    test "a full day of polling fits under the default cap" do
      assert LandObsBudget.full_day_calls() < LandObsBudget.default_cap()
      assert LandObsBudget.default_cap() <= LandObsBudget.max_cap()
    end
  end

  describe "reserve/0" do
    test "counts each reservation on the database clock's UTC day" do
      Application.put_env(:wallop_core, :land_obs_daily_cap, 900)
      day = today()

      for n <- 1..5, do: assert(LandObsBudget.reserve() == {:ok, n})
      assert count(day) == 5
      assert [%{utc_day: ^day, calls: 5}] = Ash.read!(LandObsCallCount, authorize?: false)
    end

    test "another day's count doesn't count against today" do
      Application.put_env(:wallop_core, :land_obs_daily_cap, 3)
      yesterday = Date.add(today(), -1)

      Repo.query!("INSERT INTO land_obs_call_counts (utc_day, calls) VALUES ($1, 900)", [
        yesterday
      ])

      assert LandObsBudget.reserve() == {:ok, 1}
      assert count(yesterday) == 900
    end

    test "up to the cap is allowed; past it is refused, and still counted" do
      Application.put_env(:wallop_core, :land_obs_daily_cap, 2)

      assert LandObsBudget.reserve() == {:ok, 1}
      assert LandObsBudget.reserve() == {:ok, 2}
      assert LandObsBudget.reserve() == {:error, :daily_cap, 3}
      assert LandObsBudget.reserve() == {:error, :daily_cap, 4}
      assert count(today()) == 4
    end

    test "reservations from several processes each get their own count" do
      Application.put_env(:wallop_core, :land_obs_daily_cap, 900)
      parent = self()

      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())
            LandObsBudget.reserve()
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert results |> Enum.map(fn {:ok, n} -> n end) |> Enum.sort() == Enum.to_list(1..10)
    end

    test "unset, the cap is the default" do
      Application.delete_env(:wallop_core, :land_obs_daily_cap)
      assert LandObsBudget.cap() == 800
    end

    test "actors can't read or write the counter" do
      assert {:error, %Ash.Error.Forbidden{}} =
               LandObsCallCount
               |> Ash.Changeset.for_create(:reserve, %{utc_day: today()})
               |> Ash.create(actor: %{id: "someone"})

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(LandObsCallCount, actor: %{id: "someone"})
    end
  end
end
