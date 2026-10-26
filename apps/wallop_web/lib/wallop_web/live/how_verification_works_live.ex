defmodule WallopWeb.HowVerificationWorksLive do
  use WallopWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "How verification works",
       example_proof_url: WallopWeb.ExampleProof.url()
     ), layout: {WallopWeb.Layouts, :root}}
  end
end
