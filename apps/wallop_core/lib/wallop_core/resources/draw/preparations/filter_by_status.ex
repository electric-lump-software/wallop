defmodule WallopCore.Resources.Draw.Preparations.FilterByStatus do
  @moduledoc """
  Filters `:list` by the comma-separated `status` argument; rejects unknown
  values. The allowed values are the `status` attribute's `one_of`
  constraint, so a new status is accepted without changing this module.
  """
  use Ash.Resource.Preparation

  alias Ash.Error.Query.InvalidArgument
  alias Ash.Resource.Info
  alias WallopCore.Resources.Draw

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case Ash.Query.get_argument(query, :status) do
      nil ->
        query

      value ->
        allowed = statuses()
        parts = value |> String.split(",") |> Enum.map(&String.trim/1)

        if Enum.all?(parts, &(&1 in allowed)) do
          statuses = parts |> Enum.uniq() |> Enum.map(&String.to_existing_atom/1)
          Ash.Query.filter(query, status in ^statuses)
        else
          Ash.Query.add_error(
            query,
            InvalidArgument.exception(
              field: :status,
              message: "must be a comma-separated list of: " <> Enum.join(allowed, ", ")
            )
          )
        end
    end
  end

  # Read at runtime: reading Draw's attributes at compile time here would
  # make Draw and this module depend on each other.
  defp statuses do
    Draw
    |> Info.attribute(:status)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
    |> Enum.map(&Atom.to_string/1)
  end
end
