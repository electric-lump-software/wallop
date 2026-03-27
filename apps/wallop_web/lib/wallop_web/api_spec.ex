defmodule WallopWeb.ApiSpec do
  @moduledoc "Generates the Wallop! OpenAPI spec from Ash resource definitions."

  @description """
  Provably fair random draw API. Every result is cryptographically committed before \
  entropy is known, and permanently verifiable.

  ## Entry IDs and GDPR

  **Do not submit personally identifiable information (PII) as entry IDs.**

  The entry list is hashed into a permanent, public proof record that cannot be deleted \
  without breaking the cryptographic proof. If you use email addresses, names, or other \
  personal data as entry IDs, you will be unable to honour a GDPR removal request.

  Use opaque identifiers instead — a UUID or numeric ID from your own system. Keep the \
  mapping from ID to person in your own database, where it can be deleted independently \
  of the Wallop! proof record.
  """

  @spec generate() :: OpenApiSpex.OpenApi.t()
  def generate do
    AshJsonApi.OpenApi.spec(
      [
        domains: [WallopCore.Domain],
        open_api_title: "Wallop! API",
        open_api_version: "1.0",
        phoenix_endpoint: WallopWeb.Endpoint,
        modify_open_api: &__MODULE__.modify_spec/3
      ],
      nil
    )
  end

  @doc false
  def modify_spec(spec, _conn, _opts) do
    bearer_scheme = %OpenApiSpex.SecurityScheme{
      type: "http",
      scheme: "bearer",
      description: "API key issued by Wallop!. Pass as a Bearer token in the Authorization header."
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
