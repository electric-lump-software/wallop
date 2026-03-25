defmodule WallopCore.Entropy.CallbackUrl do
  @moduledoc """
  Validates callback URLs for webhook delivery.

  Requires HTTPS and rejects private/internal IP addresses to prevent SSRF.
  """

  @doc """
  Validate a callback URL.

  Returns `:ok` or `{:error, reason}`.
  """
  def validate(url) when is_binary(url) do
    with {:ok, uri} <- parse_url(url),
         :ok <- validate_scheme(uri),
         :ok <- validate_host(uri) do
      validate_not_private(uri)
    end
  end

  def validate(_), do: {:error, "invalid URL"}

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: nil} -> {:error, "invalid URL"}
      %URI{host: nil} -> {:error, "invalid URL"}
      %URI{host: ""} -> {:error, "invalid URL"}
      uri -> {:ok, uri}
    end
  end

  defp validate_scheme(%URI{scheme: "https"}), do: :ok
  defp validate_scheme(_), do: {:error, "must be HTTPS"}

  defp validate_host(%URI{host: host}) do
    if host in ["localhost", "127.0.0.1", "::1", "0.0.0.0"] do
      {:error, "cannot use localhost or loopback address"}
    else
      :ok
    end
  end

  defp validate_not_private(%URI{host: host}) do
    case resolve_ip(host) do
      {:ok, ip} -> check_private(ip)
      {:error, _} -> {:error, "cannot resolve hostname"}
    end
  end

  defp resolve_ip(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> resolve_via_dns(charlist)
    end
  end

  defp resolve_via_dns(charlist) do
    case :inet.getaddr(charlist, :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :inet.getaddr(charlist, :inet6)
    end
  end

  defp check_private({10, _, _, _}), do: {:error, "cannot use private IP address"}

  defp check_private({172, b, _, _}) when b >= 16 and b <= 31,
    do: {:error, "cannot use private IP address"}

  defp check_private({192, 168, _, _}), do: {:error, "cannot use private IP address"}
  defp check_private({127, _, _, _}), do: {:error, "cannot use private IP address"}
  defp check_private({0, 0, 0, 0}), do: {:error, "cannot use private IP address"}
  defp check_private({0, 0, 0, 0, 0, 0, 0, 1}), do: {:error, "cannot use private IP address"}
  defp check_private(_), do: :ok
end
