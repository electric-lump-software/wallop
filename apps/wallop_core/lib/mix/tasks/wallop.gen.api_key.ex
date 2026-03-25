defmodule Mix.Tasks.Wallop.Gen.ApiKey do
  use Mix.Task

  @shortdoc "Generate a new API key"
  @moduledoc @shortdoc

  @impl true
  def run([name | _]) do
    Mix.Task.run("app.start")

    {:ok, api_key} =
      Ash.ActionInput.for_action(WallopCore.Resources.ApiKey, :create, %{name: name})
      |> Ash.run_action(domain: WallopCore.Domain)

    raw_key = Ash.Resource.get_metadata(api_key, :raw_key)

    Mix.shell().info("""

    API Key created successfully!

      Name:   #{api_key.name}
      Prefix: #{api_key.key_prefix}
      Key:    #{raw_key}

    Save this key now — it cannot be retrieved again.
    """)
  end

  def run(_) do
    Mix.shell().error("Usage: mix wallop.gen.api_key \"Name\"")
  end
end
