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
      elixirc_paths: elixirc_paths(Mix.env()),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_json_api, "~> 1.0"},
      {:ash_postgres, "~> 2.0"},
      {:bcrypt_elixir, "~> 3.0"},
      {:fair_pick, path: "../../../fair_pick"},
      {:jcs, "~> 0.2.0"},
      {:jason, "~> 1.4"},
      {:oban, "~> 2.18"},
      {:req, "~> 0.5"},
      {:ash_cloak, "~> 0.2"},
      {:cloak_ecto, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:simple_sat, "~> 0.1", only: [:dev, :test]}
    ]
  end
end
