defmodule Wallop.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.3.0",
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      aliases: aliases(),
      releases: [
        wallop: [
          version: "0.3.0",
          applications: [wallop_core: :permanent, wallop_web: :permanent]
        ]
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["ecto.create", "ecto.migrate", "run apps/wallop_core/priv/repo/seeds.exs"],
      reset: ["ecto.drop", "setup"]
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:dotenvy, "~> 0.8", only: [:dev, :test]}
    ]
  end
end
