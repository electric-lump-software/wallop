defmodule WallopCore.PolicyConventionTest do
  @moduledoc """
  Convention test: every resource registered with `WallopCore.Domain` MUST
  declare `Ash.Policy.Authorizer` in its authorizers list.

  Without an authorizer, Ash skips policy enforcement entirely and every
  action succeeds regardless of actor. An earlier audit sweep found six out
  of nine resources had no authorizer at all, and the missing authorization
  was invisible by inspection because the resources had no
  `policies do ... end` block to draw the eye.

  This test fails loudly if a future resource is added without an authorizer.
  Don't delete it — file an `authorize_if(always())` exception for any
  intentionally-public resource and keep the convention.
  """
  use ExUnit.Case, async: true

  # AshPaperTrail generates version resources at compile time and they
  # don't accept the standard `authorizers:` option directly. Exempt with
  # this allowlist so the convention test still catches every other
  # resource.
  @paper_trail_exempt [
    WallopCore.Resources.Operator.Version
  ]

  test "every WallopCore.Domain resource declares Ash.Policy.Authorizer" do
    resources = Ash.Domain.Info.resources(WallopCore.Domain) -- @paper_trail_exempt

    missing =
      Enum.reject(resources, fn resource ->
        Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(resource)
      end)

    assert missing == [],
           """
           The following resources are registered with WallopCore.Domain but
           do not declare Ash.Policy.Authorizer in their authorizers list:

           #{Enum.map_join(missing, "\n", fn r -> "  - #{inspect(r)}" end)}

           Without an authorizer, Ash skips policy enforcement entirely and
           every action succeeds regardless of actor. Add the authorizer:

               use Ash.Resource,
                 ...
                 authorizers: [Ash.Policy.Authorizer]

           Then add a `policies do ... end` block. If the resource is
           intentionally publicly-accessible, document that explicitly with
           `policy action(...) do authorize_if(always()) end` rather than
           leaving the authorizer off.
           """
  end
end
