defmodule WallopCore.Vault do
  @moduledoc "Cloak vault for encrypting sensitive fields (webhook secrets)."
  use Cloak.Vault, otp_app: :wallop_core
end
