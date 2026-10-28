defmodule WallopCore.DatabaseUrlTest do
  use ExUnit.Case, async: true

  alias WallopCore.DatabaseUrl

  @url "postgresql://wallop_api:old-pass@db.internal:5432/wallop"

  test "without a separate password, the URL is used as it is" do
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

  test "host, port, user, database and query are kept" do
    url = "postgresql://wallop_api:old@db.internal:6543/wallop?ssl=true"

    assert DatabaseUrl.build(url, "abc") ==
             "postgresql://wallop_api:abc@db.internal:6543/wallop?ssl=true"
  end

  test "the result parses back to the separate password" do
    built = DatabaseUrl.build(@url, "abc123XYZ")
    assert Ecto.Repo.Supervisor.parse_url(built)[:password] == "abc123XYZ"
    assert Ecto.Repo.Supervisor.parse_url(built)[:username] == "wallop_api"
  end

  test "an empty password is refused" do
    assert_raise ArgumentError, ~r/non-empty/, fn -> DatabaseUrl.build(@url, "") end
  end

  test "a password that would need escaping is refused, without echoing it" do
    for password <- ["has space", "a/b", "a@b", "a:b", "a+b=", "a%41"] do
      error = assert_raise ArgumentError, fn -> DatabaseUrl.build(@url, password) end
      refute error.message =~ password
    end
  end

  test "a URL with no user is refused, without echoing the URL" do
    error =
      assert_raise ArgumentError, fn ->
        DatabaseUrl.build("postgresql://db.internal:5432/wallop", "abc")
      end

    refute error.message =~ "db.internal"
  end
end
