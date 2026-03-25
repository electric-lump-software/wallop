defmodule WallopCore.Domain do
  @moduledoc "Core domain for Wallop resources."
  use Ash.Domain, otp_app: :wallop_core, extensions: [AshJsonApi.Domain]

  json_api do
    routes do
      base_route "/draws", WallopCore.Resources.Draw do
        index(:read)
        get(:read, route: "/:id")
        post(:create)
        patch(:execute, route: "/:id/execute")
      end
    end
  end

  resources do
    resource(WallopCore.Resources.ApiKey)
    resource(WallopCore.Resources.Draw)
  end
end
