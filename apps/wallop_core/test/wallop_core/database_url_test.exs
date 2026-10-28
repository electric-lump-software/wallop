defmodule WallopCore.DatabaseUrlTest do
  use ExUnit.Case, async: true

  alias WallopCore.DatabaseUrl

  @url "postgresql://wallop_api:old-pass@db.internal:5432/wallop"

  defp parsed(url), do: Ecto.Repo.Supervisor.parse_url(url)

  test "without a separate password, a valid URL is used as it is" do
    assert DatabaseUrl.build(@url, nil) == @url
  end

  test "a separate password replaces the one in the URL" do
    assert DatabaseUrl.build(@url, "New-pass_1.2~3") ==
             "postgresql://wallop_api:New-pass_1.2~3@db.internal:5432/wallop"
  end

  test "a separate password is added to a URL that has none" do
    assert DatabaseUrl.build("postgresql://wallop_api@db.internal:5432/wallop", "abc123") ==
             "postgresql://wallop_api:abc123@db.internal:5432/wallop"
  end

  test "any characters in the password reach Ecto unchanged, and nothing else moves" do
    for password <- ["a/b+c=", "p@ss:word", "with space", "100%", "?#&", "ünï"] do
      opts = parsed(DatabaseUrl.build(@url, password))
      assert opts[:password] == password
      assert opts[:username] == "wallop_api"
      assert opts[:hostname] == "db.internal"
      assert opts[:port] == 5432
      assert opts[:database] == "wallop"
    end
  end

  test "host, port, user, database and query are kept, including awkward ones" do
    cases = [
      {"postgresql://wallop_api:old@db.internal:6543/wallop?ssl=true", "wallop_api",
       "db.internal", 6543},
      {"postgresql://u%40x:old@db.internal:5432/wallop", "u@x", "db.internal", 5432},
      {"postgresql://u@x:old@db.internal:5432/wallop", "u@x", "db.internal", 5432},
      {"postgresql://wallop_api:old@[::1]:5432/wallop", "wallop_api", "::1", 5432}
    ]

    for {url, user, host, port} <- cases do
      opts = parsed(DatabaseUrl.build(url, "abc"))
      assert opts[:password] == "abc"
      assert opts[:username] == user
      assert opts[:hostname] == host
      assert opts[:port] == port
      assert opts[:database] == "wallop"
    end

    assert parsed(DatabaseUrl.build("postgresql://u:o@db.internal:5432/wallop?ssl=true", "abc"))[
             :ssl
           ] == true
  end

  test "an empty password is refused" do
    assert_raise ArgumentError, ~r/empty/, fn -> DatabaseUrl.build(@url, "") end
  end

  test "a URL with no user is refused" do
    assert_raise ArgumentError, ~r/must name a user/, fn ->
      DatabaseUrl.build("postgresql://db.internal:5432/wallop", "abc")
    end
  end

  test "malformed URLs are refused without echoing the URL or either password" do
    for url <- [
          "postgresql://wallop_api:old-pass@db.internal:5432",
          "postgresql://wallop_api:old-pass@db.internal:5432/wallop/",
          "postgresql://wallop_api:old-pass@db.internal:abc/wallop",
          "postgresql://wallop_api:old-pass@/wallop",
          "postgresql://wallop_api:old-pass@db.internal:5432/wallop?timeout=abc",
          "postgresql://wallop_api:old-pass@db.internal:5432/wallop?pool_size=1x"
        ],
        password <- [nil, "NEW-SECRET"] do
      error = assert_raise ArgumentError, fn -> DatabaseUrl.build(url, password) end
      refute error.message =~ "old-pass"
      refute error.message =~ "NEW-SECRET"
      refute error.message =~ "db.internal"
    end
  end
end
