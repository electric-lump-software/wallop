defmodule Mix.Tasks.Wallop.Gen.Openapi do
  @shortdoc "Generates the OpenAPI spec and writes it to priv/openapi.json"
  @moduledoc """
  Generates the Wallop! OpenAPI spec from Ash resource definitions and writes
  it to `priv/openapi.json`.

      mix wallop.gen.openapi

  Run this task whenever the API changes and commit the updated file. CI will
  verify the committed spec matches the generated spec on every push.
  """

  use Mix.Task

  @output_path "priv/openapi.json"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    spec = WallopWeb.ApiSpec.generate()
    json = Jason.encode!(spec, pretty: true)

    File.write!(@output_path, json <> "\n")
    Mix.shell().info("Wrote OpenAPI spec to #{@output_path}")
  end
end
