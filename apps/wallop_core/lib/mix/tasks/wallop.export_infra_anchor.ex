defmodule Mix.Tasks.Wallop.ExportInfraAnchor do
  @moduledoc """
  Export the wallop infrastructure signing-key keyring as anchor records,
  for population of the bundled trust anchor in `wallop_verifier`.

  ## Usage

      mix wallop.export_infra_anchor          # JSON output (default)
      mix wallop.export_infra_anchor --rust   # Rust const-array snippet

  Reads every `InfrastructureSigningKey` row, emits each as an anchor
  record per spec §4.2.4 (`key_id`, `public_key_hex`, `inserted_at`,
  `revoked_at` — currently always absent, since the keyring schema has
  no `revoked_at` column in 1.x). The exported records are intended to
  populate `wallop_verifier/src/anchors.rs` for tier-1 attributable mode.

  Private keys are NEVER emitted.

  Sort order: ascending by `inserted_at`. The current key is the last
  entry. Verifier-side anchor-set cadence (current + previous N within
  the 90-day grace window) is a release-engineering decision applied
  when curating the Rust file; this task emits the full keyring.

  ## Production usage

  Run from a context that can read the production keyring (an
  authenticated operator-side mix shell, a one-shot job with the prod
  database URL, etc.). The output is non-secret — it contains only
  public anchor metadata that already ships on `/infrastructure/keys`.

  ## Examples

      $ mix wallop.export_infra_anchor
      [
        {
          "key_id": "21fe31df",
          "public_key_hex": "...",
          "inserted_at": "2026-04-09T12:34:56.789012Z",
          "revoked_at": null
        }
      ]

      $ mix wallop.export_infra_anchor --rust
      pub const ANCHORS: &[Anchor] = &[
          Anchor {
              key_id: "21fe31df",
              public_key_hex: "...",
              inserted_at: "2026-04-09T12:34:56.789012Z",
              revoked_at: None,
          },
      ];
  """
  use Mix.Task

  alias WallopCore.Resources.InfrastructureSigningKey

  require Ash.Query

  @shortdoc "Export wallop infra signing keys as anchor records (JSON or Rust)"

  @switches [rust: :boolean]

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    rust? = Keyword.get(opts, :rust, false)

    rows =
      InfrastructureSigningKey
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(authorize?: false)

    if rows == [] do
      Mix.shell().error("""
      No infrastructure signing keys found.

      Run `mix wallop.bootstrap_infrastructure_key` first, then re-run
      this task.
      """)

      exit({:shutdown, 1})
    end

    anchor_records = Enum.map(rows, &to_anchor_record/1)

    if rust? do
      IO.puts(format_rust(anchor_records))
    else
      IO.puts(format_json(anchor_records))
    end
  end

  defp to_anchor_record(row) do
    # `revoked_at` is intentionally always nil/absent: the keyring
    # schema has no `revoked_at` column in 1.x. Emitting the field
    # explicitly (rather than omitting it) keeps the JSON shape
    # consistent with the verifier-side anchor record schema, which
    # MUST be either an RFC 3339 timestamp or absent — and "absent"
    # serialises cleanly as null.
    %{
      key_id: row.key_id,
      public_key_hex: Base.encode16(row.public_key, case: :lower),
      inserted_at: WallopCore.Time.to_rfc3339_usec(row.inserted_at),
      revoked_at: nil
    }
  end

  defp format_json(records) do
    Jason.encode_to_iodata!(records, pretty: true)
  end

  defp format_rust(records) do
    body = Enum.map_join(records, ",\n", &format_rust_entry/1)

    """
    pub const ANCHORS: &[Anchor] = &[
    #{body},
    ];
    """
  end

  defp format_rust_entry(%{
         key_id: key_id,
         public_key_hex: public_key_hex,
         inserted_at: inserted_at,
         revoked_at: nil
       }) do
    """
        Anchor {
            key_id: "#{key_id}",
            public_key_hex: "#{public_key_hex}",
            inserted_at: "#{inserted_at}",
            revoked_at: None,
        }\
    """
  end
end
