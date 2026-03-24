defmodule WallopWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :wallop_web,
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
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:wallop_core, in_umbrella: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
