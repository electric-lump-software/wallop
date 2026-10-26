defmodule WallopWeb.ExampleProof do
  @moduledoc """
  The example proof the home page and the verification explainer link to,
  from `config :wallop_web, :example_proof_url` (set by `EXAMPLE_PROOF_URL`
  at runtime). Nil when unset; the pages then leave the links out.
  """

  @doc "The example proof URL, or nil."
  @spec url() :: String.t() | nil
  def url do
    case Application.get_env(:wallop_web, :example_proof_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end
end
