defmodule WallopCore.LogTest do
  use ExUnit.Case, async: false

  alias WallopCore.Log

  setup do
    # Isolate the salt across tests. A test that mutated the salt would
    # silently decohere other tests' redaction expectations.
    previous_salt = :persistent_term.get({Log, :salt}, :undefined)
    :persistent_term.erase({Log, :salt})

    on_exit(fn ->
      :persistent_term.erase({Log, :salt})

      case previous_salt do
        :undefined -> :ok
        salt -> :persistent_term.put({Log, :salt}, salt)
      end
    end)

    :ok
  end

  describe "redact_id/1" do
    test "returns 10 lowercase hex chars for a valid UUID" do
      id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      out = Log.redact_id(id)

      assert is_binary(out)
      assert byte_size(out) == 10
      assert Regex.match?(~r/\A[0-9a-f]{10}\z/, out)
    end

    test "same input within a run produces the same output" do
      id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      assert Log.redact_id(id) == Log.redact_id(id)
    end

    test "different inputs produce different outputs (collision rarely)" do
      a = Log.redact_id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
      b = Log.redact_id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")

      refute a == b
    end

    test "rotating the salt changes the output for the same input" do
      id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
      first = Log.redact_id(id)

      :persistent_term.erase({Log, :salt})

      second = Log.redact_id(id)

      # Overwhelmingly likely to differ (2^-40 false-match). If this
      # flakes, we have a bigger problem.
      refute first == second
    end

    test "nil is tagged as \"nil\" rather than crashing or leaking" do
      assert Log.redact_id(nil) == "nil"
    end

    test "non-string inputs are tagged rather than crashing or leaking" do
      assert Log.redact_id(42) == "<non-string>"
      assert Log.redact_id(%{}) == "<non-string>"
      assert Log.redact_id(:an_atom) == "<non-string>"
    end
  end

  describe "redact_ids/1" do
    test "maps over a list" do
      ids = [
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      ]

      out = Log.redact_ids(ids)
      assert length(out) == 2
      assert Enum.all?(out, &(byte_size(&1) == 10))
    end
  end

  describe "span_attrs/1" do
    test "redacts values of known id keys" do
      attrs = %{
        "draw.id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "draw_id" => "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        "entry_id" => "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        "operator_id" => "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        "api_key_id" => "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        "id" => "ffffffff-ffff-4fff-8fff-ffffffffffff"
      }

      out = Log.span_attrs(attrs)

      for key <- Map.keys(attrs) do
        assert byte_size(out[key]) == 10, "expected 10-char redaction for key #{inspect(key)}"
        refute out[key] == attrs[key], "key #{inspect(key)} was NOT redacted"
      end
    end

    test "passes non-id keys through unchanged" do
      attrs = %{
        "draw_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "duration_ms" => 42,
        "status" => "completed",
        "drand_round" => 12_345
      }

      out = Log.span_attrs(attrs)

      assert out["duration_ms"] == 42
      assert out["status"] == "completed"
      assert out["drand_round"] == 12_345
      # draw_id still redacted
      assert byte_size(out["draw_id"]) == 10
    end

    test "accepts atom keys" do
      attrs = %{
        draw_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        status: "completed"
      }

      out = Log.span_attrs(attrs)

      assert byte_size(out[:draw_id]) == 10
      assert out[:status] == "completed"
    end

    test "leaves id-keyed non-binary values alone (defensive)" do
      attrs = %{"draw_id" => 42, "entry_id" => nil}
      out = Log.span_attrs(attrs)

      # Values that aren't binaries pass through unchanged — we only
      # redact strings, not ints or nils that happen to sit under an
      # id-shaped key.
      assert out["draw_id"] == 42
      assert out["entry_id"] == nil
    end
  end

  describe "salt lifecycle" do
    test "salt is generated once per VM run and cached" do
      # First call creates the salt; subsequent calls reuse it.
      _ = Log.redact_id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
      salt_1 = :persistent_term.get({Log, :salt})

      _ = Log.redact_id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
      salt_2 = :persistent_term.get({Log, :salt})

      assert salt_1 == salt_2
      assert byte_size(salt_1) == 32
    end

    test "salt generation emits a telemetry event" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "log-salt-generated-#{inspect(ref)}",
        [:wallop_core, :log, :salt_generated],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:salt_generated, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("log-salt-generated-#{inspect(ref)}")
      end)

      _ = Log.redact_id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")

      assert_receive {:salt_generated, %{count: 1}, %{pid: pid}}, 500
      assert pid == self()
    end
  end
end
