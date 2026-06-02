defmodule Mix.Tasks.Wallop.Vault.VerifyRotation do
  @moduledoc """
  Report Cloak cipher-tag distribution across every Vault-encrypted column.

  ## Usage

      mix wallop.vault.verify_rotation

  Read-only: emits one SELECT per encrypted column, parses each row's
  Cloak tag prefix, and prints a per-column count grouped into:

    * current  — rows under `WallopCore.Vault.Config.current_tag/0`
    * previous — rows under `WallopCore.Vault.Config.previous_tag/0`
    * unknown  — anything else (corruption, foreign tag, or NULL)

  Exits with status 1 if ANY row still carries the previous tag — that
  is the signal `wallop.vault.migrate` (Wave B) has not yet finished
  re-encrypting under the new key. Exits 1 also when any row's tag is
  unknown, since that is a corruption / foreign-data alarm.

  Touches no data. Safe to run on production.

  ## Performance characteristics

  Each encrypted column is scanned with a full `SELECT column FROM table`
  and parsed in Elixir. O(N) over every Vault-encrypted row. This is
  intentional — keeping the TLV parse in Elixir means we use the same
  code path as Cloak itself, instead of duplicating tag layout knowledge
  in SQL. Fine for the operator/infrastructure key tables which have
  tens of rows; fine for `api_keys` at expected operator scale. Run
  this task during a rotation window, not in a hot loop. If `api_keys`
  ever grows past five-digit row counts, push the substring extract
  into SQL with a `GROUP BY` on the prefix.

  ## Where this fits

  Step 4 of the rotation procedure documented in `WallopCore.Vault.Config`:

    1. Bump tags in `WallopCore.Vault.Config`.
    2. Deploy with both `VAULT_KEY` and `VAULT_KEY_OLD` set.
    3. Run `mix wallop.vault.migrate` (Wave B) to re-encrypt rows.
    4. **Run this task.** Refuses to declare success while any row still
       carries the previous tag.
    5. Drop `VAULT_KEY_OLD` and redeploy.
  """
  use Mix.Task

  alias WallopCore.Repo
  alias WallopCore.Vault.Config, as: VaultConfig

  @shortdoc "Report Cloak cipher-tag distribution across Vault-encrypted columns"

  # {table, column, format}.
  #   :binary       — bytea column, raw Cloak ciphertext.
  #   :base64_text  — text column storing base64-encoded Cloak ciphertext.
  @encrypted_columns [
    {"operator_signing_keys", "private_key", :binary},
    {"infrastructure_signing_keys", "private_key", :binary},
    {"api_keys", "webhook_secret", :base64_text}
  ]

  def run(_args) do
    Mix.Task.run("app.start")

    case inspect_and_report() do
      :ok -> :ok
      {:error, _reason} -> exit({:shutdown, 1})
    end
  end

  @doc """
  Runs the inspection and prints the report. Returns:

    * `:ok` — every row carries the current tag.
    * `{:error, :rotation_incomplete}` — at least one row still carries the
      previous tag. `mix wallop.vault.migrate` (Wave B) must finish first.
    * `{:error, :unknown_tag}` — at least one row has a tag this build does
      not know about. Investigate before continuing.

  Split out from `run/1` so it can be tested without invoking `exit/1`.
  """
  @spec inspect_and_report() :: :ok | {:error, :rotation_incomplete | :unknown_tag}
  def inspect_and_report do
    current = VaultConfig.current_tag()
    previous = VaultConfig.previous_tag()

    Mix.shell().info("""

    Vault rotation status
      current tag:  #{current}
      previous tag: #{previous}
    """)

    results = Enum.map(@encrypted_columns, &inspect_column/1)

    print_table(results)

    previous_rows = Enum.sum(Enum.map(results, fn r -> r.counts.previous end))
    unknown_rows = Enum.sum(Enum.map(results, fn r -> r.counts.unknown end))

    cond do
      previous_rows > 0 ->
        Mix.shell().error("""

        Rotation incomplete: #{previous_rows} row(s) still carry the previous tag.
        Run `mix wallop.vault.migrate` (Wave B) to re-encrypt them under the
        current key before dropping VAULT_KEY_OLD.
        """)

        {:error, :rotation_incomplete}

      unknown_rows > 0 ->
        Mix.shell().error("""

        #{unknown_rows} row(s) have an unrecognised tag. This is not a normal
        rotation state — investigate before continuing. A row could be NULL,
        corrupted, or encrypted under a tag this build does not know about.
        """)

        {:error, :unknown_tag}

      true ->
        Mix.shell().info("All rows carry the current tag. Safe to drop VAULT_KEY_OLD.")
        :ok
    end
  end

  defp inspect_column({table, column, format}) do
    current = VaultConfig.current_tag()
    previous = VaultConfig.previous_tag()

    %Postgrex.Result{rows: rows} =
      Repo.query!(~s|SELECT "#{column}" FROM "#{table}"|, [])

    counts =
      Enum.reduce(rows, %{current: 0, previous: 0, unknown: 0}, fn [value], acc ->
        case extract_tag(value, format) do
          ^current -> Map.update!(acc, :current, &(&1 + 1))
          ^previous -> Map.update!(acc, :previous, &(&1 + 1))
          _other -> Map.update!(acc, :unknown, &(&1 + 1))
        end
      end)

    %{table: table, column: column, counts: counts, total: length(rows)}
  end

  # Returns the Cloak tag string, or `nil` for malformed / NULL rows.
  # Cloak's TLV layout is `<<1, len>> <> tag <> ciphertext`. Tags >= 128
  # bytes use a multi-byte length encoding (see Cloak.Tags.Encoder) —
  # wallop tags are short ASCII ("AES.GCM.V1") and will never approach
  # that boundary. Anything claiming a single-byte length >= 128 here
  # is malformed and routed to the unknown bucket, where it belongs.
  defp extract_tag(nil, _format), do: nil

  defp extract_tag(value, :base64_text) do
    case Base.decode64(value) do
      {:ok, bytes} -> extract_tag(bytes, :binary)
      :error -> nil
    end
  end

  defp extract_tag(<<_reserved, len, rest::binary>>, :binary)
       when len < 128 and byte_size(rest) >= len do
    <<tag::binary-size(len), _ciphertext::binary>> = rest
    tag
  end

  defp extract_tag(_other, _format), do: nil

  defp print_table(results) do
    header =
      "  #{pad("table.column", 48)}  #{pad("current", 8)}  #{pad("previous", 9)}  #{pad("unknown", 8)}  total"

    Mix.shell().info(header)
    Mix.shell().info("  " <> String.duplicate("-", String.length(header) - 2))

    Enum.each(results, fn r ->
      Mix.shell().info(
        "  #{pad("#{r.table}.#{r.column}", 48)}  " <>
          "#{pad(Integer.to_string(r.counts.current), 8)}  " <>
          "#{pad(Integer.to_string(r.counts.previous), 9)}  " <>
          "#{pad(Integer.to_string(r.counts.unknown), 8)}  " <>
          Integer.to_string(r.total)
      )
    end)

    Mix.shell().info("")
  end

  defp pad(s, width), do: String.pad_trailing(s, width)
end
