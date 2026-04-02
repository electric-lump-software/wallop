defmodule WallopCore.BoundaryTest do
  @moduledoc """
  Ensures wallop_core never references wallop_web modules.

  This boundary is critical: wallop_core is open source and used as a
  dependency by closed-source consuming apps. If core depends on web,
  consuming apps would need to include wallop_web — breaking the
  separation between the open protocol layer and the web presentation.
  """
  use ExUnit.Case, async: true

  @core_source_dir "apps/wallop_core/lib"

  test "wallop_core does not reference WallopWeb modules" do
    violations =
      Path.wildcard("#{@core_source_dir}/**/*.ex")
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> String.contains?(line, "WallopWeb") end)
        |> Enum.reject(fn {line, _} -> String.starts_with?(String.trim(line), "#") end)
        |> Enum.map(fn {line, line_no} ->
          relative = Path.relative_to(file, "apps/wallop_core")
          "  #{relative}:#{line_no} — #{String.trim(line)}"
        end)
      end)

    assert violations == [],
           "wallop_core must not reference WallopWeb modules:\n#{Enum.join(violations, "\n")}"
  end

  test "wallop_core does not reference wallop-app modules" do
    violations =
      Path.wildcard("#{@core_source_dir}/**/*.ex")
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> String.contains?(line, "WallopApp") end)
        |> Enum.reject(fn {line, _} -> String.starts_with?(String.trim(line), "#") end)
        |> Enum.map(fn {line, line_no} ->
          relative = Path.relative_to(file, "apps/wallop_core")
          "  #{relative}:#{line_no} — #{String.trim(line)}"
        end)
      end)

    assert violations == [],
           "wallop_core must not reference WallopApp modules:\n#{Enum.join(violations, "\n")}"
  end
end
