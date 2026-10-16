defmodule WallopCore.DbClock do
  @moduledoc """
  The database clock, in UTC: the clock the database guards read "now" on
  (`statement_timestamp() AT TIME ZONE 'UTC'`). Code that must agree with
  the guards about whether a deadline has passed asks here, not the BEAM.
  """

  alias WallopCore.Repo

  @doc "The database clock now, in UTC."
  @spec now() :: DateTime.t()
  def now do
    %{rows: [[naive]]} = Repo.query!("SELECT statement_timestamp() AT TIME ZONE 'UTC'")
    DateTime.from_naive!(naive, "Etc/UTC")
  end
end
