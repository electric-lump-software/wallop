defmodule WallopCore.Resources.Draw.CheckUrlTest do
  use ExUnit.Case, async: true

  alias WallopCore.Resources.Draw.CheckUrl

  describe "validate/1" do
    test "accepts https URLs" do
      assert :ok = CheckUrl.validate("https://example.com/check?id=123")
      assert :ok = CheckUrl.validate("https://example.com/check")
      assert :ok = CheckUrl.validate("https://check.example.com")
    end

    test "rejects http URLs" do
      assert {:error, _} = CheckUrl.validate("http://example.com/check")
    end

    test "rejects javascript: URLs" do
      assert {:error, _} = CheckUrl.validate("javascript:alert(1)")
    end

    test "rejects data: URLs" do
      assert {:error, _} = CheckUrl.validate("data:text/html,<script>alert(1)</script>")
    end

    test "rejects vbscript: URLs" do
      assert {:error, _} = CheckUrl.validate("vbscript:msgbox(1)")
    end

    test "rejects file: URLs" do
      assert {:error, _} = CheckUrl.validate("file:///etc/passwd")
    end

    test "rejects ftp: URLs" do
      assert {:error, _} = CheckUrl.validate("ftp://example.com/a")
    end

    test "rejects scheme-less strings" do
      assert {:error, _} = CheckUrl.validate("example.com/check")
    end

    test "rejects empty string" do
      assert {:error, _} = CheckUrl.validate("")
    end

    test "rejects non-binary input" do
      assert {:error, _} = CheckUrl.validate(nil)
      assert {:error, _} = CheckUrl.validate(42)
      assert {:error, _} = CheckUrl.validate(%{})
    end

    test "rejects URLs with no host" do
      assert {:error, _} = CheckUrl.validate("https://")
    end

    test "rejects URLs longer than 2048 chars" do
      long_path = String.duplicate("a", 2050)
      assert {:error, msg} = CheckUrl.validate("https://example.com/#{long_path}")
      assert msg =~ "2048"
    end

    test "accepts URLs at exactly 2048 chars" do
      prefix = "https://example.com/"
      filler = String.duplicate("a", 2048 - String.length(prefix))
      url = prefix <> filler
      assert String.length(url) == 2048
      assert :ok = CheckUrl.validate(url)
    end
  end
end
