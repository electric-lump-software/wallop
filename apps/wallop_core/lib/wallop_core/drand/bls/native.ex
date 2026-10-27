defmodule WallopCore.Drand.Bls.Native do
  @moduledoc false

  @crate_dir "native/drand_bls"

  if is_nil(System.find_executable("cargo")) do
    raise CompileError,
      description:
        "wallop_core needs a Rust toolchain (1.91 or later; #{@crate_dir}/rust-toolchain.toml " <>
          "pins the version used) to build its drand BLS NIF, and `cargo` is not on the PATH. " <>
          "Install one with rustup (https://rustup.rs) and compile again."
  end

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
    cargo: {:system, "--locked"}

  @doc false
  @spec verify_g1(binary(), non_neg_integer(), binary()) :: boolean()
  def verify_g1(_pubkey, _round, _sig), do: :erlang.nif_error(:nif_not_loaded)
end
