defmodule WallopCore.Drand.Bls.Native do
  @moduledoc false
  # The drand BLS NIF, built from `native/drand_bls` at compile time.
  # Call it through `WallopCore.Drand.Bls`, never directly.
  #
  # If the library fails to load, this module fails to load with it, and
  # `WallopCore.Application` refuses to boot (see `WallopCore.Drand.Bls.self_test!/0`):
  # a node that can't check drand signatures must not run draws.

  # The crate is built only from its committed Cargo.lock. Rustler runs
  # `cargo metadata` without `--locked`, which would quietly rewrite a stale
  # lock file before the build, so the lock is checked here first. Rustler
  # resolves the crate path against the app directory; so does this.
  @crate_dir "native/drand_bls"

  case System.cmd("cargo", ~w(metadata --locked --format-version=1),
         cd: @crate_dir,
         stderr_to_stdout: true
       ) do
    {_metadata, 0} ->
      :ok

    {output, _status} ->
      raise CompileError,
        description:
          "#{@crate_dir}/Cargo.lock does not match Cargo.toml; the NIF is built only " <>
            "from the committed lock file. cargo said:\n" <> output
  end

  use Rustler,
    otp_app: :wallop_core,
    crate: "drand_bls",
    # `--locked`, a global cargo flag: the build itself also refuses to
    # change the lock file.
    cargo: {:system, "--locked"}

  @doc false
  @spec verify_g1(binary(), non_neg_integer(), binary()) :: boolean()
  def verify_g1(_pubkey, _round, _sig), do: :erlang.nif_error(:nif_not_loaded)
end
