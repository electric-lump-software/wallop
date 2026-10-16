defmodule WallopCore.Attacks.FetchJobSuppressionTest do
  @moduledoc """
  One planted row in oban_jobs must not suppress an hour's observation
  fetch.

  `WeatherObservationWorker` is unique on `weather_time` with
  `period: :infinity`. With Oban's default unique states, which include
  `completed`, a `completed` job row for a future hour (planted, or the real
  job's state flipped) would make every later insert for that hour a silent
  conflict: no fetch, no telemetry, and every draw of the hour falls back
  to drand alone. So uniqueness is among live jobs only
  (`states: :incomplete`). A second job for an hour is harmless: the store
  is first write wins.
  """
  use WallopCore.DataCase, async: false

  alias WallopCore.Entropy.WeatherObservationWorker
  alias WallopCore.Repo

  test "a completed job row for a future hour doesn't block the hour's fetch job" do
    hour =
      DateTime.utc_now()
      |> DateTime.add(2 * 86_400)
      |> DateTime.truncate(:second)
      |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 0}})

    # The attacker's row: a job for hour H already marked completed.
    {:ok, planted} = Oban.insert(WeatherObservationWorker.new_for_hour(hour))

    Repo.query!(
      "UPDATE oban_jobs SET state = 'completed', completed_at = now() WHERE id = $1",
      [planted.id]
    )

    # Later, a draw locks for H and the hour's fetch job is inserted. It
    # must be a real, scheduled job.
    {:ok, job} = Oban.insert(WeatherObservationWorker.new_for_hour(hour))

    refute job.conflict?, "the hour's fetch job was swallowed by a completed row"
    assert job.state in ["scheduled", "available"]
  end

  test "a live job for the hour still makes a second insert a conflict" do
    hour =
      DateTime.utc_now()
      |> DateTime.add(3 * 86_400)
      |> DateTime.truncate(:second)
      |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 0}})

    {:ok, first} = Oban.insert(WeatherObservationWorker.new_for_hour(hour))
    refute first.conflict?

    {:ok, second} = Oban.insert(WeatherObservationWorker.new_for_hour(hour))
    assert second.conflict?
    assert second.id == first.id
  end
end
