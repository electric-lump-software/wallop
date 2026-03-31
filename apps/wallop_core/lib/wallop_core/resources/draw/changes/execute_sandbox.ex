defmodule WallopCore.Resources.Draw.Changes.ExecuteSandbox do
  @moduledoc """
  Executes a draw using the published sandbox seed.

  Transitions directly from `awaiting_entropy` to `completed` using a
  hardcoded, deterministic seed. The seed is SHA-256("wallop-sandbox"),
  publicly known, so sandbox draws produce predictable outcomes — making
  them useless for real draws but suitable for integration testing.

  Guarded by `config :wallop_core, :allow_sandbox_execution` which must
  be `true` (defaults to `true` in dev/test, `false` in prod).
  """
  use Ash.Resource.Change

  # SHA-256("wallop-sandbox")
  # Computed: echo -n "wallop-sandbox" | shasum -a 256
  @sandbox_seed_hex "f3c5f1bc419eaaf3624e958a5aed289336ef5085260773e87f6a615cea443652"

  @doc "Returns the published sandbox seed hex string."
  @spec sandbox_seed_hex() :: String.t()
  def sandbox_seed_hex, do: @sandbox_seed_hex

  @impl true
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.context()) :: Ash.Changeset.t()
  def change(changeset, _opts, _context) do
    if sandbox_allowed?() do
      Ash.Changeset.before_action(changeset, &run_sandbox_draw/1)
    else
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: "sandbox execution is not allowed in this environment"
      )
    end
  end

  @spec run_sandbox_draw(Ash.Changeset.t()) :: Ash.Changeset.t()
  defp run_sandbox_draw(changeset) do
    draw = changeset.data
    atom_entries = WallopCore.Entries.load_for_draw(draw.id)

    # Integrity check: recompute entry hash and verify it matches
    {recomputed_hash, _canonical} = WallopCore.Protocol.entry_hash(atom_entries)

    if recomputed_hash != draw.entry_hash do
      Ash.Changeset.add_error(changeset, field: :entries, message: "entry hash mismatch")
    else
      apply_results(changeset, atom_entries, draw.winner_count)
    end
  end

  @spec apply_results(Ash.Changeset.t(), [map()], pos_integer()) :: Ash.Changeset.t()
  defp apply_results(changeset, atom_entries, winner_count) do
    seed_bytes = Base.decode16!(@sandbox_seed_hex, case: :lower)
    results = FairPick.draw(atom_entries, seed_bytes, winner_count)

    string_results =
      Enum.map(results, fn %{position: pos, entry_id: id} ->
        %{"position" => pos, "entry_id" => id}
      end)

    changeset
    |> Ash.Changeset.force_change_attribute(:results, string_results)
    |> Ash.Changeset.force_change_attribute(:seed, @sandbox_seed_hex)
    |> Ash.Changeset.force_change_attribute(:seed_source, :sandbox)
    |> Ash.Changeset.force_change_attribute(:seed_json, nil)
    |> Ash.Changeset.force_change_attribute(:executed_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:status, :completed)
  end

  @spec sandbox_allowed?() :: boolean()
  defp sandbox_allowed? do
    Application.get_env(:wallop_core, :allow_sandbox_execution, false)
  end
end
