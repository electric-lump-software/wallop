defmodule WallopCore.BoundaryTest do
  @moduledoc """
  Ensures wallop_core never references wallop_web or downstream consumer
  app modules.

  This boundary is critical: wallop_core is open source and used as a
  dependency by closed-source consumer apps. If core depends on web,
  consumer apps would need to include wallop_web — breaking the
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

  test "wallop_core does not reference downstream consumer app modules" do
    # Belt-and-braces check that no core-layer file accidentally introduces
    # a reference to a known consumer-side namespace. The list below names
    # the namespaces of currently-known closed-source consumers; extend if
    # a new consumer ships and starts depending on wallop_core.
    consumer_namespaces = ["WallopApp"]

    violations =
      Path.wildcard("#{@core_source_dir}/**/*.ex")
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} ->
          Enum.any?(consumer_namespaces, &String.contains?(line, &1))
        end)
        |> Enum.reject(fn {line, _} -> String.starts_with?(String.trim(line), "#") end)
        |> Enum.map(fn {line, line_no} ->
          relative = Path.relative_to(file, "apps/wallop_core")
          "  #{relative}:#{line_no} — #{String.trim(line)}"
        end)
      end)

    assert violations == [],
           "wallop_core must not reference downstream consumer modules:\n#{Enum.join(violations, "\n")}"
  end
end
