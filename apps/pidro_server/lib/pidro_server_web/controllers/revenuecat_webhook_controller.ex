defmodule PidroServerWeb.RevenueCatWebhookController do
  @moduledoc """
  `POST /webhooks/revenuecat` (PID-125). RevenueCat names the player whose
  purchases changed; `PidroServer.Entitlements.receive_event/1` stores the
  event and syncs that player. A 500 makes RevenueCat retry.
  """

  use PidroServerWeb, :controller

  alias PidroServer.Entitlements
  alias PidroServer.RevenueCat

  def create(conn, params) do
    cond do
      not RevenueCat.configured?() -> send_resp(conn, :service_unavailable, "")
      not authorized?(conn) -> send_resp(conn, :unauthorized, "")
      true -> take_event(conn, params)
    end
  end

  defp take_event(conn, %{"event" => event}) do
    case Entitlements.receive_event(event) do
      ok when ok in [:ok, :duplicate] -> send_resp(conn, :ok, "")
      {:error, :bad_event} -> send_resp(conn, :bad_request, "")
      {:error, _reason} -> send_resp(conn, :internal_server_error, "")
    end
  end

  defp take_event(conn, _params), do: send_resp(conn, :bad_request, "")

  defp authorized?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Plug.Crypto.secure_compare(token, RevenueCat.webhook_secret())
      _other -> false
    end
  end
end
