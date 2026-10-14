defmodule WallopCore.JsonApiErrors do
  @moduledoc """
  AshJsonApi error handler for the draw API.

  - Update actions run through Ash's bulk path, whose record index leaks into
    the pointer (`/data/attributes/0/winner_count`). Remove it (only a numeric index directly after
    `/data/attributes/`; deeper array pointers are left alone).
  - Constraint messages arrive as templates ("at least %{min}") with the
    values in `meta`. Fill in strings, numbers and atoms; leave any other
    value (a `one_of` list, a map) as the template.

  An error handler that raises turns a 400 into a 500 on every route, so
  any exception here returns the error unchanged.
  """

  require Logger

  @spec handle(AshJsonApi.Error.t(), map()) :: AshJsonApi.Error.t()
  def handle(%AshJsonApi.Error{} = error, _context) do
    %{
      error
      | source_pointer: fix_pointer(error.source_pointer),
        detail: interpolate(error.detail, error.meta)
    }
  rescue
    exception ->
      Logger.warning("JsonApiErrors: left error unchanged: #{Exception.message(exception)}")
      error
  end

  defp fix_pointer(pointer) when is_binary(pointer),
    do: Regex.replace(~r{\A/data/attributes/\d+/}, pointer, "/data/attributes/")

  defp fix_pointer(pointer), do: pointer

  defp interpolate(detail, meta) when is_binary(detail) and is_map(meta) do
    Regex.replace(~r/%\{(\w+)\}/, detail, fn whole, name -> fill(whole, name, meta) end)
  end

  defp interpolate(detail, _meta), do: detail

  defp fill(whole, name, meta) do
    case Enum.find(meta, fn {key, _value} -> to_string(key) == name end) do
      {_key, value} -> if sentence_value?(value), do: to_string(value), else: whole
      nil -> whole
    end
  end

  defp sentence_value?(value),
    do: is_binary(value) or is_number(value) or (is_atom(value) and not is_nil(value))
end
