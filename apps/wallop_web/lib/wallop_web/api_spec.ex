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
    |> tidy_list_draws()
    |> type_v6_datetimes()
  end

  # AshJsonApi leaves microsecond UTC datetimes untyped. Type the
  # observation-weather fields: the lock's `draw_at` argument and the draw's
  # `expected_result_at`. Other datetime fields are left as they are.
  defp type_v6_datetimes(spec) do
    attributes = [Access.key(:properties), Access.key(:attributes), Access.key(:properties)]

    lock_attributes =
      [Access.key(:paths), Access.key("/draws/{id}/lock"), Access.key(:patch)] ++
        [Access.key(:requestBody), Access.key(:content), Access.key("application/vnd.api+json")] ++
        [Access.key(:schema), Access.key(:properties), Access.key(:data)] ++ attributes

    spec
    |> update_in(
      [Access.key(:components), Access.key(:schemas), Access.key("draw")] ++
        attributes ++ [Access.key("expected_result_at")],
      &nullable_datetime/1
    )
    |> update_in(lock_attributes ++ [Access.key("draw_at")], &nullable_datetime/1)
  end

  defp nullable_datetime(%{"description" => description}),
    do: %OpenApiSpex.Schema{
      type: :string,
      format: :"date-time",
      nullable: true,
      description: description
    }

  # AshJsonApi describes keyset paging generically (limit/offset wording,
  # before/count, no max) and its 200 schema forbids `links`. GET /draws is
  # keyset-only, capped at 100, and returns `links.next`.
  defp tidy_list_draws(spec) do
    update_in(spec, [Access.key(:paths), Access.key("/draws"), Access.key(:get)], fn op ->
      %{op | parameters: Enum.map(op.parameters, &tidy_parameter/1)}
      |> update_in([Access.key(:responses), Access.key(200)], &add_links/1)
    end)
  end

  defp tidy_parameter(%{name: "page"} = param) do
    limit = %{type: :integer, minimum: 1, maximum: 100, default: 50}

    schema = %{
      param.schema
      | properties: %{after: %{type: :string}, limit: limit},
        example: %{limit: 50}
    }

    %{
      param
      | description:
          "Keyset pagination: `limit` (1 to 100, default 50) and `after` (a cursor from `links.next`).",
        schema: schema
    }
  end

  defp tidy_parameter(param), do: param

  defp add_links(response) do
    nullable_url = %{type: :string, nullable: true}

    next = %{
      type: :string,
      nullable: true,
      description: "URL of the next page; `null` (key present) on the last page."
    }

    links = %{
      type: :object,
      properties: Map.put(Map.new(~w(self first prev)a, &{&1, nullable_url}), :next, next)
    }

    update_in(
      response,
      [Access.key(:content), Access.key("application/vnd.api+json"), Access.key(:schema)],
      fn schema -> %{schema | properties: Map.put(schema.properties, :links, links)} end
    )
  end
end
