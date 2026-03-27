defmodule WallopCore.EntriesTest do
  use ExUnit.Case, async: true

  alias WallopCore.Entries

  describe "to_atom_keys/1" do
    test "converts string-keyed maps to atom-keyed maps" do
      entries = [
        %{"id" => "entry1", "weight" => 1},
        %{"id" => "entry2", "weight" => 2}
      ]

      result = Entries.to_atom_keys(entries)

      assert result == [
               %{id: "entry1", weight: 1},
               %{id: "entry2", weight: 2}
             ]
    end

    test "passes through atom-keyed maps unchanged" do
      entries = [
        %{id: "entry1", weight: 1},
        %{id: "entry2", weight: 2}
      ]

      result = Entries.to_atom_keys(entries)

      assert result == entries
    end

    test "returns empty list for empty input" do
      result = Entries.to_atom_keys([])

      assert result == []
    end

    test "handles mixed string-keyed and atom-keyed maps" do
      entries = [
        %{"id" => "entry1", "weight" => 1},
        %{id: "entry2", weight: 2},
        %{"id" => "entry3", "weight" => 3}
      ]

      result = Entries.to_atom_keys(entries)

      assert result == [
               %{id: "entry1", weight: 1},
               %{id: "entry2", weight: 2},
               %{id: "entry3", weight: 3}
             ]
    end
  end
end
