defmodule WallopCore.Domain do
  @moduledoc "Core domain for Wallop resources."
  use Ash.Domain, otp_app: :wallop_core

  resources do
    resource(WallopCore.Resources.ApiKey)
  end
end
