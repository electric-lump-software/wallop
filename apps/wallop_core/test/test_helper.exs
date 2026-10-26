# Invariants whose task has not landed yet are excluded by default. See
# WallopCore.Invariants.SuiteTest (test/wallop_core/invariants/).
ExUnit.configure(exclude: WallopCore.InvariantCase.pending_tags())

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(WallopCore.Repo, :manual)
