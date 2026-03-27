defmodule WallopWeb.ApiSpecController do
  use WallopWeb, :controller

  @description "Provably fair random draw API. Every result is cryptographically committed before " <>
                 "entropy is known, and permanently verifiable."

  def index(conn, _params) do
    spec =
      AshJsonApi.OpenApi.spec(
        [
          domains: [WallopCore.Domain],
          open_api_title: "Wallop! API",
          open_api_version: "1.0",
          phoenix_endpoint: WallopWeb.Endpoint,
          modify_open_api: &__MODULE__.modify_spec/3
        ],
        conn
      )

    json(conn, spec)
  end

  @doc false
  def modify_spec(spec, _conn, _opts) do
    bearer_scheme = %OpenApiSpex.SecurityScheme{
      type: "http",
      scheme: "bearer",
      description:
        "API key issued by Wallop!. Pass as a Bearer token in the Authorization header."
    }

    spec
    |> put_in([Access.key(:info), Access.key(:description)], @description)
    |> put_in(
      [Access.key(:components), Access.key(:security_schemes)],
      %{"bearerAuth" => bearer_scheme}
    )
    |> Map.put(:security, [%{"bearerAuth" => []}])
  end
end
