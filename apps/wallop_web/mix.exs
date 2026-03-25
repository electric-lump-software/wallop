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
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {WallopWeb.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:wallop_core, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:ash_phoenix, "~> 2.0"},
      {:bandit, "~> 1.0"},
      {:ash_json_api, "~> 1.0"},
      {:open_api_spex, "~> 3.16"},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.9", runtime: Mix.env() == :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
