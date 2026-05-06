defmodule WallopWeb.RouterRoutesTest do
  @moduledoc """
  Regression test for the public route set. Two assertions cover two
  distinct surfaces, both of which can grow silently:

  1. **Phoenix top-level routes** — adding a new scope, route, or
     `forward(...)` to `WallopWeb.Router` extends the public HTTP surface.
     Pinned via `WallopWeb.Router.__routes__/0`.

  2. **AshJsonApi resource × action × method × path** — adding `json_api do`
     to any resource in `WallopCore.Domain` (or a new action inside an
     existing `json_api` block) auto-mounts a new endpoint under the
     `forward("/", AshJsonApiRouter)` wildcard inside `/api/v1`. The
     Phoenix route table is invariant under this change, so the surface
     in (1) above does NOT catch it. Pinned separately via
     `Ash.Domain.Info.resources/1` + `AshJsonApi.Resource.Info.routes/1`,
     which is the structural data AshJsonApi's internal router dispatches
     on (format-stable across AshJsonApi versions, unlike the formatted
     route strings).

  Either assertion failing means a contributor added a public endpoint.
  The failure message names exactly what appeared or disappeared. When
  the addition is intentional, update the corresponding allowlist below
  AND document the new endpoint in `apps/wallop_web/lib/wallop_web/router.ex`.
  """
  use ExUnit.Case, async: true

  # Sorted alphabetically by (verb-string, path). Verb `*` is Phoenix's
  # representation of `forward(...)` — a route that swallows any path under
  # the matched scope. Wildcards here are deliberate; new ones are not.
  @expected_routes [
    # AshJsonApi router for WallopCore.Domain — currently exposes Draw
    # at /api/v1/draws. Adding `json_api do` to another resource in the
    # domain extends what this wildcard covers; that addition MUST be
    # accompanied by an explicit allowlist update on this test.
    {:*, "/api/v1"},
    {:get, "/"},
    {:get, "/api/docs"},
    {:get, "/api/open_api"},
    {:get, "/api/v1/draws/:id/entries"},
    {:get, "/api/v1/health"},
    {:get, "/health"},
    {:get, "/how-verification-works"},
    {:get, "/infrastructure/key"},
    {:get, "/infrastructure/keys"},
    {:get, "/live/proof/:id"},
    {:get, "/live/proof/:id/:entry_id"},
    {:get, "/operator/:slug"},
    {:get, "/operator/:slug/executions"},
    {:get, "/operator/:slug/executions/:sequence"},
    {:get, "/operator/:slug/key"},
    {:get, "/operator/:slug/keys"},
    {:get, "/operator/:slug/keyring-pin.json"},
    {:get, "/operator/:slug/receipts"},
    {:get, "/operator/:slug/receipts/:sequence"},
    {:get, "/proof/:id"},
    {:get, "/proof/:id/:entry_id"},
    {:get, "/proof/:id/entries"},
    {:get, "/proof/:id/json"},
    {:get, "/proof/:id/pdf"},
    {:get, "/transparency"},
    {:patch, "/api/v1/draws/:id/entries"}
  ]

  test "Phoenix top-level route set matches the explicit allowlist" do
    actual_routes =
      WallopWeb.Router.__routes__()
      |> Enum.map(fn r -> {r.verb, r.path} end)
      |> Enum.sort()

    expected_sorted = Enum.sort(@expected_routes)

    new_routes = actual_routes -- expected_sorted
    removed_routes = expected_sorted -- actual_routes

    assert new_routes == [] and removed_routes == [],
           """
           Phoenix top-level route set changed.

           NEW routes (not in allowlist):
           #{format_phoenix(new_routes)}

           REMOVED routes (in allowlist but no longer in router):
           #{format_phoenix(removed_routes)}

           If these changes are intentional, update `@expected_routes` in
           `apps/wallop_web/test/wallop_web/router_routes_test.exs`.
           """
  end

  # AshJsonApi-served route surface — pinned as
  # {resource module, action atom, HTTP method, path}. This is the
  # structural data AshJsonApi's internal router dispatches on; format
  # stable across AshJsonApi versions (unlike the formatted route
  # strings). New `json_api do` blocks on resources extend THIS set
  # without touching `WallopWeb.Router.__routes__/0`, so the Phoenix
  # allowlist above does not catch them — this test does.
  @expected_ash_json_api_routes [
    {WallopCore.Resources.Draw, :read, :get, "/draws"},
    {WallopCore.Resources.Draw, :read, :get, "/draws/:id"},
    {WallopCore.Resources.Draw, :create, :post, "/draws"},
    {WallopCore.Resources.Draw, :add_entries, :patch, "/draws/:id/entries"},
    {WallopCore.Resources.Draw, :update_winner_count, :patch, "/draws/:id/winner_count"},
    {WallopCore.Resources.Draw, :lock, :patch, "/draws/:id/lock"}
  ]

  test "AshJsonApi resource/action/method set matches the explicit allowlist" do
    # AshJsonApi exposes routes from two sources: resource-level
    # (`json_api do { routes do ... end }` inside an Ash.Resource) and
    # domain-level (`json_api do { routes do base_route ... end }` inside
    # an Ash.Domain). Concatenate both to capture the full surface.
    domain_routes =
      WallopCore.Domain
      |> AshJsonApi.Domain.Info.routes()
      |> Enum.map(fn route -> {route.resource, route.action, route.method, route.route} end)

    resource_routes =
      WallopCore.Domain
      |> Ash.Domain.Info.resources()
      |> Enum.flat_map(fn resource ->
        resource
        |> AshJsonApi.Resource.Info.routes()
        |> Enum.map(fn route -> {resource, route.action, route.method, route.route} end)
      end)

    actual_routes = Enum.sort(domain_routes ++ resource_routes)

    expected_sorted = Enum.sort(@expected_ash_json_api_routes)

    new_routes = actual_routes -- expected_sorted
    removed_routes = expected_sorted -- actual_routes

    assert new_routes == [] and removed_routes == [],
           """
           AshJsonApi-served route surface changed.

           NEW routes (not in allowlist):
           #{format_ash(new_routes)}

           REMOVED routes (in allowlist but no longer served):
           #{format_ash(removed_routes)}

           A new entry here means an Ash resource gained `json_api do`
           configuration (or a new action was added inside an existing
           `json_api` block), and the route is now served at /api/v1/<path>
           via the AshJsonApi wildcard forward. Confirm the endpoint is
           reviewed and intended, then update `@expected_ash_json_api_routes`
           in `apps/wallop_web/test/wallop_web/router_routes_test.exs`.
           """
  end

  defp format_phoenix([]), do: "  (none)"

  defp format_phoenix(routes) do
    Enum.map_join(routes, "\n", fn {verb, path} -> "  #{verb} #{path}" end)
  end

  defp format_ash([]), do: "  (none)"

  defp format_ash(routes) do
    Enum.map_join(routes, "\n", fn {resource, action, method, path} ->
      "  #{method} #{path}  (#{inspect(resource)}.#{action})"
    end)
  end
end
