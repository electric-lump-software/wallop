defmodule WallopWeb.ExampleProof do
  @moduledoc """
  The example proof the home page and the verification explainer link to,
  from `config :wallop_web, :example_proof_url` (set by `EXAMPLE_PROOF_URL`
  at runtime). Nil when unset; the pages then leave the links out.
  """

  @doc """
  Parses `EXAMPLE_PROOF_URL` for `config/runtime.exs`: nil when unset or
  empty, the URL when it starts with `https://`. Anything else raises, so
  the boot stops rather than linking somewhere unexpected.
  """
  @spec parse_env!(String.t() | nil) :: String.t() | nil
  def parse_env!(value) when value in [nil, ""], do: nil

  def parse_env!("https://" <> rest = url) when rest != "", do: url

  def parse_env!(other) do
    raise ArgumentError,
          "EXAMPLE_PROOF_URL must be an https:// URL of a completed proof page, " <>
            "or unset; got #{inspect(other)}"
  end

  @doc "The example proof URL, or nil."
  @spec url() :: String.t() | nil
  def url do
    case Application.get_env(:wallop_web, :example_proof_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end
end
