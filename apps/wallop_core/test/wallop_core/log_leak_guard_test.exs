defmodule WallopCore.LogLeakGuardTest do
  @moduledoc """
  Source-tree guard that forbids raw UUID / identifier interpolation in
  log lines and telemetry attribute maps.

  Spec §4.3 forbids observability emission carrying entry UUIDs, draw
  content, or anything beyond counts and timings. `WallopCore.Log`
  provides `redact_id/1` / `span_attrs/1` for this purpose; this test
  catches regressions where a call site bypasses them.

  ## What this catches

  - `Logger.info("... \#{draw.id} ...")` — raw draw UUID in log.
  - `Logger.warning("... \#{entry_id} ...")` — raw entry UUID in log.
  - `:telemetry.execute(name, measurements, %{"draw.id" => draw.id, ...})` — raw UUID in span metadata.
  - `Tracer.set_attributes(%{"draw.id" => draw.id, ...})` — same.
  - `Tracer.with_span name, attributes: %{"draw.id" => draw.id, ...} do` — same.

  ## What this doesn't catch (deliberately)

  - Internal references like `PubSub.broadcast("draw:\#{draw.id}", ...)`
    (pubsub topic is internal routing, not log output).
  - `Ash.get(Draw, draw.id)` (DB call, not observability).
  - Oban job `args: %{"draw_id" => draw_id}` (separate V-11 audit
    item — leaking via oban_jobs table, not via log stream).
  - Any line that passes the ID through `Log.redact_id/1` or
    `Log.span_attrs/1`.

  The rule is practical, not exhaustive: it triggers on the specific
  patterns that show up in log output, not on every possible identifier
  reference. Follow-ups can tighten if needed.
  """
  use ExUnit.Case, async: true

  @id_patterns [
    ~r/#\{[a-z_][a-z0-9_]*\.id\}/,
    ~r/#\{[a-z_][a-z0-9_]*_id\}/,
    ~r/=>\s*[a-z_][a-z0-9_]*\.id(\s|,|\})/,
    ~r/=>\s*[a-z_][a-z0-9_]*_id(\s|,|\})/
  ]

  @log_emitters [
    "Logger.info",
    "Logger.warning",
    "Logger.error",
    "Logger.debug",
    ":telemetry.execute",
    "Tracer.set_attributes",
    "Tracer.with_span"
  ]

  @source_roots [
    "apps/wallop_core/lib",
    "apps/wallop_web/lib"
  ]

  test "no raw UUID interpolation in log emitters" do
    violations =
      @source_roots
      |> Enum.flat_map(&collect_ex_files/1)
      |> Enum.flat_map(&scan_file/1)

    if violations != [] do
      formatted =
        Enum.map_join(violations, "\n\n", fn {file, line, text} ->
          "  #{file}:#{line}\n    #{String.trim(text)}"
        end)

      flunk("""
      Found raw UUID / identifier interpolation in log emitters — violates spec §4.3 and the V-03 hardening rule.

      Route every identifier through `WallopCore.Log.redact_id/1` or
      `WallopCore.Log.span_attrs/1` before emission.

      Offenders:

      #{formatted}
      """)
    end
  end

  defp collect_ex_files(root) do
    root
    |> Path.wildcard()
    |> Enum.flat_map(fn dir ->
      if File.dir?(dir) do
        Path.wildcard(Path.join([dir, "**", "*.{ex,exs}"]))
      else
        []
      end
    end)
  end

  defp scan_file(path) do
    # Self-exempt: WallopCore.Log IS the redaction module and its
    # tests necessarily exercise ID-shaped strings in asserts.
    if String.contains?(path, "log.ex") or
         String.contains?(path, "log_test.exs") or
         String.contains?(path, "log_leak_guard_test.exs") do
      []
    else
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(&line_is_violation?/1)
      |> Enum.map(fn {line, idx} -> {path, idx, line} end)
    end
  end

  defp line_is_violation?({line, _idx}) do
    emits_log?(line) and
      matches_id_pattern?(line) and
      not uses_redaction?(line)
  end

  defp emits_log?(line) do
    Enum.any?(@log_emitters, &String.contains?(line, &1))
  end

  defp matches_id_pattern?(line) do
    Enum.any?(@id_patterns, &Regex.match?(&1, line))
  end

  defp uses_redaction?(line) do
    String.contains?(line, "Log.redact_id") or
      String.contains?(line, "Log.redact_ids") or
      String.contains?(line, "Log.span_attrs")
  end
end
