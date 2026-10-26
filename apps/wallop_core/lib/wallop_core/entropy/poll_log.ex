defmodule WallopCore.Entropy.PollLog do
  @moduledoc """
  What a failed poll may put in a log line. Only an atom or an
  `{atom, integer}` passes unchanged (`:missing_hour`,
  `{:unexpected_status, 503}`); any other tuple is cut to its leading atom
  (`{:transport, :timeout}` logs as `:transport`), and anything else is
  `:other`. So a string, a struct, a map or a URL can never reach the log,
  whatever a client returns: not the API key, and not a response body.
  Telemetry still carries the client's full error term.
  """

  @doc "The loggable form of a poll error term."
  @spec term(term()) :: atom() | {atom(), integer()}
  def term(reason) when is_atom(reason), do: reason
  def term({tag, n}) when is_atom(tag) and is_integer(n), do: {tag, n}
  def term(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: leading(elem(reason, 0))
  def term(_), do: :other

  defp leading(tag) when is_atom(tag), do: tag
  defp leading(_), do: :other
end
