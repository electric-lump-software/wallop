defmodule WallopWeb.ProofPreLockViewVectorTest do
  @moduledoc """
  Cross-language conformance vector for the pre-lock proof page
  allowlist (`spec/vectors/pre_lock_wide_gap_v1.json`,
  `spec/protocol.md` §4.3).

  Loads `spec/vectors/pre_lock_wide_gap_v1.json` and asserts that
  `WallopWeb.ProofPreLockView.from_draw/2` produces byte-identical
  projections from the documented inputs. The vector is shared with
  the Rust verifier (`wallop_verifier`) and any future
  re-implementation; passing this test in Elixir is one half of the
  cross-language contract.

  The vector also pins **forensic strings** — substrings that MUST
  NOT appear anywhere in the projected view. A future PR that
  accidentally widens the allowlist would surface a forbidden
  substring and fail this test.
  """
  use ExUnit.Case, async: true

  alias WallopWeb.ProofPreLockView

  @vector_path Path.expand("../../../../spec/vectors/pre_lock_wide_gap_v1.json", __DIR__)

  describe "happy-path vectors" do
    setup do
      vector =
        @vector_path
        |> File.read!()
        |> Jason.decode!()

      {:ok, vector: vector}
    end

    test "all happy-path vectors produce the documented expected_view", %{vector: vector} do
      for v <- vector["vectors"] do
        draw = build_draw(v["draw_input"])
        operator = build_operator(v["operator_input"])

        actual_view = ProofPreLockView.from_draw(draw, operator) |> normalise_for_compare()
        expected_view = v["expected_view"] |> normalise_for_compare()

        assert actual_view == expected_view,
               "vector '#{v["name"]}' did not project to the expected view"
      end
    end

    test "no forensic substring appears in any projected view", %{vector: vector} do
      for v <- vector["vectors"] do
        draw = build_draw(v["draw_input"])
        operator = build_operator(v["operator_input"])

        # Use inspect/1 — captures every field on the struct, including
        # any nested maps. More forensically thorough than Jason.encode
        # (which would skip non-encodable values).
        rendered = ProofPreLockView.from_draw(draw, operator) |> inspect(limit: :infinity)

        for forbidden <- v["forensic_strings_that_must_not_appear_in_view"] || [] do
          refute String.contains?(rendered, forbidden),
                 "vector '#{v["name"]}' leaked forensic string '#{forbidden}': #{rendered}"
        end
      end
    end

    test "allowlist matches the struct shape", %{vector: vector} do
      vector_allowlist = vector["allowlist"] |> Enum.map(&String.to_atom/1) |> Enum.sort()

      struct_keys =
        %ProofPreLockView{} |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert vector_allowlist == struct_keys,
             """
             Vector allowlist drift detected.

             The `allowlist` array in spec/vectors/pre_lock_wide_gap_v1.json
             must match the struct shape of WallopWeb.ProofPreLockView.

             Vector allowlist: #{inspect(vector_allowlist)}
             Struct keys:      #{inspect(struct_keys)}

             If the change is intentional, update both the struct and
             the vector — re-implementers depend on the vector as the
             cross-language source of truth.
             """
    end
  end

  describe "negative vectors" do
    setup do
      vector =
        @vector_path
        |> File.read!()
        |> Jason.decode!()

      {:ok, vector: vector}
    end

    test "non-open status raises ArgumentError matching the documented expected_error", %{
      vector: vector
    } do
      for nv <- vector["negative_vectors"] || [] do
        draw = build_draw(nv["draw_input"])
        operator = build_operator(nv["operator_input"])

        assert_raise ArgumentError, ~r/#{nv["expected_error"]}/, fn ->
          ProofPreLockView.from_draw(draw, operator)
        end
      end
    end
  end

  # JSON decodes everything as strings; the live struct uses atom keys
  # for status. Coerce status string → atom for the comparison.
  defp build_draw(json_map) do
    json_map
    |> Map.new(fn
      {"status", v} -> {:status, String.to_atom(v)}
      {"stage_timestamps", v} -> {:stage_timestamps, v}
      {k, v} -> {String.to_atom(k), v}
    end)
  end

  defp build_operator(nil), do: nil

  defp build_operator(json_map) do
    Map.new(json_map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  # Normalise both sides of the comparison: turn the struct into a map,
  # convert status atom back to string for direct comparison with the
  # JSON-loaded expected_view, and stringify keys.
  defp normalise_for_compare(%ProofPreLockView{} = view) do
    view
    |> Map.from_struct()
    |> normalise_for_compare()
  end

  defp normalise_for_compare(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalise_value(v)}
      {k, v} -> {k, normalise_value(v)}
    end)
  end

  defp normalise_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalise_value(:open), do: "open"
  defp normalise_value(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp normalise_value(v) when is_map(v), do: normalise_for_compare(v)
  defp normalise_value(v), do: v
end
