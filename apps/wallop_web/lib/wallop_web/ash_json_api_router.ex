defmodule WallopWeb.AshJsonApiRouter do
  @moduledoc "AshJsonApi router — forwards JSON:API requests to Ash domains."
  use AshJsonApi.Router,
    domains: [WallopCore.Domain]
end
