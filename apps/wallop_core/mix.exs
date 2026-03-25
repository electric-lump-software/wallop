defmodule WallopCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :wallop_core,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {WallopCore.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},
      {:bcrypt_elixir, "~> 3.0"},
      {:fair_pick, path: "../../../fair_pick"},
      {:jcs, "~> 0.2.0"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
