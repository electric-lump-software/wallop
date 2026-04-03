defmodule WallopWeb.ProofHTML do
  use WallopWeb, :html

  import WallopWeb.Components.DrawTimeline
  import WallopWeb.Components.ProofChain
  import WallopWeb.Components.WinnerList

  embed_templates("proof_html/*")
end
