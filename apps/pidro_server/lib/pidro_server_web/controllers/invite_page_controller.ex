defmodule PidroServerWeb.InvitePageController do
  @moduledoc "Server-rendered, side-effect-free handoff for public invite links."

  use PidroServerWeb, :controller

  alias PidroServerWeb.InvitePage
  alias PidroServerWeb.InvitePage.UserAgent
  alias PidroServerWeb.InvitePreview
  alias PidroServerWeb.DeferredInviteCaptureController

  @doc "Renders a known invite in any state, or a generic branded 404."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"code" => code}) do
    device = conn |> get_req_header("user-agent") |> List.first() |> UserAgent.classify()
    crawler? = device == :crawler

    conn = prepare_response(conn)

    case InvitePreview.get(code) do
      {:ok, preview} ->
        page = InvitePage.present(preview, device)

        page =
          Map.put(
            page,
            :deferred_capture_url,
            if(page.table_action in [:join, :successor],
              do: DeferredInviteCaptureController.capture_url(page.code)
            )
          )

        render(conn, :show, page: page, crawler?: crawler?)

      {:error, :not_found} ->
        page = InvitePage.not_found(device)

        conn
        |> put_status(:not_found)
        |> render(:not_found, page: page, crawler?: crawler?)
    end
  end

  defp prepare_response(conn) do
    static_origin = PidroServerWeb.Endpoint.static_url()

    csp =
      Enum.join(
        [
          "default-src 'self'",
          "img-src 'self' data: #{static_origin}",
          "style-src 'self' #{static_origin}",
          "font-src 'self' #{static_origin}",
          "script-src 'self' #{static_origin}",
          "connect-src #{DeferredInviteCaptureController.endpoint_origin()}",
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
