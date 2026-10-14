defmodule WallopCore.JsonApiErrorsTest do
  use ExUnit.Case, async: true

  alias WallopCore.JsonApiErrors

  defp error(detail, meta, pointer \\ "/data/attributes/0/status") do
    %AshJsonApi.Error{detail: detail, meta: meta, source_pointer: pointer}
  end

  test "fills in strings, numbers and atoms" do
    assert JsonApiErrors.handle(
             error("at least %{min}, at most %{max}, not %{bad}", %{min: 1, max: 2.5, bad: :x}),
             %{}
           ).detail ==
             "at least 1, at most 2.5, not x"
  end

  test "leaves lists, maps and tuples as the template" do
    result =
      JsonApiErrors.handle(error("must be one of: %{one_of}", %{one_of: [:open, :locked]}), %{})

    assert result.detail == "must be one of: %{one_of}"
    assert result.source_pointer == "/data/attributes/status"

    assert JsonApiErrors.handle(error("bad %{x}", %{x: %{a: 1}}), %{}).detail == "bad %{x}"
    assert JsonApiErrors.handle(error("bad %{x}", %{x: {1, 2}}), %{}).detail == "bad %{x}"
  end

  test "leaves array pointers that aren't the bulk index alone" do
    assert JsonApiErrors.handle(error("x", %{}, "/data/attributes/entries/3/ref"), %{}).source_pointer ==
             "/data/attributes/entries/3/ref"
  end

  test "returns the original error rather than raising" do
    weird = %AshJsonApi.Error{detail: "x %{a}", meta: :not_a_map, source_pointer: 123}
    assert JsonApiErrors.handle(weird, %{}) == weird
  end
end
