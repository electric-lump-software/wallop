defmodule WallopCore.Resources.Draw.CheckUrlValidationTest do
  use WallopCore.DataCase, async: false

  import WallopCore.TestHelpers

  alias WallopCore.Resources.Draw

  describe "metadata.check_url validation at Draw.create" do
    setup do
      %{api_key: create_api_key()}
    end

    test "accepts draw with no metadata", %{api_key: api_key} do
      assert {:ok, _} =
               Draw
               |> Ash.Changeset.for_create(:create, %{winner_count: 1}, actor: api_key)
               |> Ash.create()
    end

    test "accepts draw with metadata that has no check_url", %{api_key: api_key} do
      assert {:ok, _} =
               Draw
               |> Ash.Changeset.for_create(
                 :create,
                 %{winner_count: 1, metadata: %{"event" => "spring-raffle"}},
                 actor: api_key
               )
               |> Ash.create()
    end

    test "accepts draw with valid https check_url", %{api_key: api_key} do
      assert {:ok, draw} =
               Draw
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   winner_count: 1,
                   metadata: %{"check_url" => "https://example.com/check-your-ticket"}
                 },
                 actor: api_key
               )
               |> Ash.create()

      assert draw.metadata["check_url"] == "https://example.com/check-your-ticket"
    end

    test "rejects draw with http:// check_url", %{api_key: api_key} do
      assert {:error, _} =
               Draw
               |> Ash.Changeset.for_create(
                 :create,
                 %{winner_count: 1, metadata: %{"check_url" => "http://example.com/check"}},
                 actor: api_key
               )
               |> Ash.create()
    end

    test "rejects draw with javascript: check_url", %{api_key: api_key} do
      assert {:error, _} =
               Draw
               |> Ash.Changeset.for_create(
                 :create,
                 %{winner_count: 1, metadata: %{"check_url" => "javascript:alert(1)"}},
                 actor: api_key
               )
               |> Ash.create()
    end

    test "rejects draw with data: check_url", %{api_key: api_key} do
      assert {:error, _} =
               Draw
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   winner_count: 1,
                   metadata: %{"check_url" => "data:text/html,<script>alert(1)</script>"}
                 },
                 actor: api_key
               )
               |> Ash.create()
    end

    test "rejects check_url > 2048 chars", %{api_key: api_key} do
      long_url = "https://example.com/#{String.duplicate("a", 2050)}"

      assert {:error, _} =
               Draw
               |> Ash.Changeset.for_create(
                 :create,
                 %{winner_count: 1, metadata: %{"check_url" => long_url}},
                 actor: api_key
               )
               |> Ash.create()
    end
  end
end
