ExUnit.configure(exclude: WallopCore.InvariantCase.pending_tags())

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(WallopCore.Repo, :manual)
