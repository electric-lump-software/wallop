defmodule WallopCore.Resources.Entry.Validations.OperatorRef do
  @moduledoc """
  Validates `Entry.operator_ref`: nil OR (≤ 64 bytes AND no control characters).

  Byte-count is enforced here because Ash's `:string` `max_length` counts
  codepoints, and the canonical `entry_hash` form pins BYTES.

  Rejected control codepoints: U+0000–U+001F, U+007F, U+2028, U+2029.
  """
  use Ash.Resource.Validation

  @max_bytes 64
  @control_codepoints MapSet.new(Enum.concat([0x00..0x1F, [0x7F, 0x2028, 0x2029]]))

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :operator_ref) do
      nil ->
        :ok

      "" ->
        :ok

      ref when is_binary(ref) ->
        check(ref)

      other ->
        {:error, field: :operator_ref, message: "must be a string or nil, got: #{inspect(other)}"}
    end
  end

  defp check(ref) do
    cond do
      byte_size(ref) > @max_bytes ->
        {:error,
         field: :operator_ref,
         message: "must be at most #{@max_bytes} bytes (got #{byte_size(ref)})"}

      has_control?(ref) ->
        {:error, field: :operator_ref, message: "must not contain control characters"}

      true ->
        :ok
    end
  end

  defp has_control?(ref) do
    ref
    |> String.to_charlist()
    |> Enum.any?(&MapSet.member?(@control_codepoints, &1))
  end
end
