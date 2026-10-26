defmodule WallopCore.NoRepoCheckoutTest do
  @moduledoc """
  No shipped code pins a database connection with `Repo.checkout` (on any
  receiver) or `DBConnection.run`. Jobs
  check a connection out per query, which is why the queue limits may add
  up to more than the pool (config/config.exs): a checkout held across an
  HTTP call or a snooze would break that.
  """
  use ExUnit.Case, async: true

  @umbrella_root Path.expand("../../../..", __DIR__)
  # Any receiver (Repo, an alias, a variable) and DBConnection.run, which
  # pins a connection the same way.
  @checkout ~r/\.\s*checkout\b|\bDBConnection\s*\.\s*run\b/

  defp hits(contents),
    do:
      for(
        {line, n} <- contents |> String.split("\n") |> Enum.with_index(1),
        line =~ @checkout,
        do: {n, String.trim(line)}
      )

  test "the pattern catches a checkout in any of its spellings" do
    assert [{1, _}] = hits("Repo.checkout(fn -> fetch() end)")
    assert [{2, _}] = hits("x = 1\nWallopCore.Repo.checkout(fn -> :ok end)")
    assert [{1, _}] = hits("Repo .checkout(fun)")
    assert [{1, _}] = hits("R.checkout(fn -> :ok end)")
    assert [{1, _}] = hits("repo.checkout(fun, timeout: 1)")
    assert [{1, _}] = hits("DBConnection.run(conn, fun)")
    assert hits("Repo.checked_out?()") == []
    assert hits("Repo.transaction(fn -> :ok end)") == []
  end

  test "no checkout anywhere in apps/*/lib" do
    files = Path.wildcard(Path.join(@umbrella_root, "apps/*/lib/**/*.{ex,exs}"))
    assert Enum.any?(files, &String.ends_with?(&1, "weather_observation_worker.ex"))

    found =
      for path <- files,
          {n, line} <- hits(File.read!(path)),
          do: "#{Path.relative_to(path, @umbrella_root)}:#{n}: #{line}"

    assert found == []
  end
end
