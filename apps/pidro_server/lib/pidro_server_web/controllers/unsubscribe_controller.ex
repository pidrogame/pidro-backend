defmodule PidroServerWeb.UnsubscribeController do
  @moduledoc """
  The update-email link in every mailing, `/unsubscribe/:token` (PID-448).

  `GET` only shows the page, because mail scanners follow links. `POST` turns
  update emails off, or back on with `choice=on`. Mail apps' own button posts
  `List-Unsubscribe=One-Click` with no session or CSRF token: the signed token
  is the only credential, and it names one player.
  """

  use PidroServerWeb, :controller

  alias PidroServer.Emails

  @csp Enum.join(
         [
           "default-src 'none'",
           "img-src 'self'",
           "style-src 'unsafe-inline'",
           "form-action 'self'",
           "base-uri 'none'",
           "frame-ancestors 'none'"
         ],
         "; "
       )

  def show(conn, %{"token" => token}) do
    case Emails.user_for_unsubscribe_token(token) do
      {:ok, user} -> page(conn, if(user.update_emails_off_at, do: :off, else: :ask), token)
      :error -> invalid(conn)
    end
  end

  def update(conn, %{"token" => token} = params) do
    choice = if params["choice"] == "on", do: :on, else: :off

    with {:ok, user} <- Emails.user_for_unsubscribe_token(token),
         {:ok, _user} <- Emails.set_update_emails(user, choice) do
      page(conn, choice, token)
    else
      _invalid -> invalid(conn)
    end
  end

  defp invalid(conn), do: conn |> put_status(:not_found) |> page(:invalid, nil)

  defp page(conn, state, token) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("x-robots-tag", "noindex")
    |> put_view(PidroServerWeb.UnsubscribeHTML)
    |> render(:show,
      state: state,
      token: token,
      support_email: Emails.delivery_setup().reply_to
    )
  end
end
