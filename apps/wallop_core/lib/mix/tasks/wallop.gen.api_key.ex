defmodule Mix.Tasks.Wallop.Gen.ApiKey do
  use Mix.Task

  @shortdoc "Generate a new API key"
  @moduledoc @shortdoc

  @impl true
  def run([name | _]) do
    Mix.Task.run("app.start")

    {:ok, api_key} =
      WallopCore.Resources.ApiKey
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(domain: WallopCore.Domain)

    raw_key = Ash.Resource.get_metadata(api_key, :raw_key)

    Mix.shell().info("""

    API Key created successfully!

      Name:           #{api_key.name}
      Prefix:         #{api_key.key_prefix}
      Key:            #{raw_key}
      Webhook Secret: #{api_key.webhook_secret}

    Save these values now — they cannot be retrieved again.
    """)
  end

  def run(_) do
    Mix.shell().error("Usage: mix wallop.gen.api_key \"Name\"")
  end
end
