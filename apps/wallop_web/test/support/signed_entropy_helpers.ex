defmodule WallopWeb.SignedEntropyHelpers do
  @moduledoc """
  Test helpers for proof pages of lock schema 6 draws: a completed draw
  in a chosen state with its execution receipt stored, and the PDF's
  HTML rendered without Gotenberg.
  """

  alias Phoenix.HTML.Safe
  alias WallopCore.{InvariantCase, OperatorInfo, Protocol, Repo}
  alias WallopWeb.{ProofPdfHTML, ProofWeather}

  @doc """
  A completed draw with its execution receipt stored as the signer
  builds it (placeholder signature), then passed through `edit` (signed
  JSON in, signed JSON out). An edited receipt is stored with triggers
  off, since the database refuses one outside its tag's states.

  `kind`: `:observed`, `:frequency` or `:fallback` under the observation
  weather tag; `{:freq, :observed}` or `{:freq, :fallback}` under the
  grid-frequency tag. `opts` go to the core helper.
  """
  def completed_signed!(kind, edit \\ nil, opts \\ []) do
    %{draw: draw, input: input, cols: cols} =
      case kind do
        {:freq, k} -> InvariantCase.completed_freq_receipt_input(k, opts)
        k -> InvariantCase.completed_v6_receipt_input(k, opts)
      end

    jcs = Protocol.build_v6_execution_payload(input)
    jcs = if edit, do: jcs |> Jason.decode!() |> edit.() |> Jcs.encode(), else: jcs

    insert = fn ->
      Repo.query!(
        """
        INSERT INTO execution_receipts (id, draw_id, operator_id, sequence, lock_receipt_hash,
          payload_jcs, signature, signing_key_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(cols.draw_id),
          Ecto.UUID.dump!(cols.operator_id),
          cols.sequence,
          cols.lock_receipt_hash,
          jcs,
          :binary.copy(<<0>>, 64),
          cols.signing_key_id
        ]
      )
    end

    if edit, do: InvariantCase.with_triggers_off(insert), else: insert.()
    Ash.get!(WallopCore.Resources.Draw, draw.id, authorize?: false)
  end

  @doc "The proof PDF's HTML for `draw`, as `WallopWeb.ProofPdf` renders it before Gotenberg."
  def pdf_html(draw) do
    {operator, receipt, execution_receipt} = OperatorInfo.for_draw(draw)

    %{
      draw: draw,
      entries: WallopCore.Entries.load_for_draw(draw.id),
      operator: operator,
      receipt: receipt,
      weather: ProofWeather.summary(draw, execution_receipt, receipt),
      winners: draw.results || [],
      public_url: "https://example.test/proof/#{draw.id}",
      generated_at: DateTime.utc_now()
    }
    |> ProofPdfHTML.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
