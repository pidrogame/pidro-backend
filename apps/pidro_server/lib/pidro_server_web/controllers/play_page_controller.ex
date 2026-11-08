defmodule PidroServerWeb.PlayPageController do
  @moduledoc "Server-rendered landing page for a player's share link, `/play/:slug`."

  use PidroServerWeb, :controller

  alias PidroServer.Accounts.{Auth, Avatars, User}
  alias PidroServerWeb.InvitePage
  alias PidroServerWeb.InvitePage.UserAgent

  @doc "Renders the named player, or the same page without a name as a 404."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"slug" => slug}) do
    device = conn |> get_req_header("user-agent") |> List.first() |> UserAgent.classify()
    conn = prepare_response(conn)

    case Auth.get_user_by_share_slug(slug) do
      %User{} = user ->
        player = %{
          display_name: User.public_name(user),
          avatar_url: Avatars.url_for(user)
        }

        render(conn, :show, page: InvitePage.player(player, slug, device), crawler?: false)

      nil ->
        conn
        |> put_status(:not_found)
        |> render(:show, page: InvitePage.player(nil, slug, device), crawler?: false)
    end
  end

  defp prepare_response(conn) do
    static_origin = PidroServerWeb.Endpoint.static_url()

    csp =
      Enum.join(
        [
          "default-src 'self'",
          "img-src 'self' data: #{static_origin} #{PidroServerWeb.Endpoint.url()}",
          "style-src 'self' #{static_origin}",
          "script-src 'self' #{static_origin}",
          "connect-src #{PidroServerWeb.DeferredInviteCaptureController.endpoint_origin()}",
          "object-src 'none'",
          "base-uri 'none'",
          "form-action 'none'",
          "frame-ancestors 'none'"
        ],
        "; "
      )

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("vary", "User-Agent")
    |> put_resp_header("content-security-policy", csp)
  end
end
