defmodule PidroServerWeb.ResetPasswordPageController do
  @moduledoc """
  The password-reset email's link in a browser, `/app/reset-password` (PID-515):
  a computer, or a phone without Pidro. With Pidro installed the app opens the
  same link on its own reset screen.

  `GET` only checks the token, because mail scanners follow links. `POST`
  resets with `Auth.reset_user_password/2`, the API's reset, and signs in
  nowhere: the page tells the player to open Pidro.
  """

  use PidroServerWeb, :controller

  alias PidroServer.Accounts.Auth
  alias PidroServerWeb.InvitePage
  alias PidroServerWeb.ResetPasswordPageHTML

  def show(conn, %{"token" => token}) do
    if Auth.password_reset_token_live?(token),
      do: page(conn, :form, token: token),
      else: invalid(conn)
  end

  def show(conn, _params), do: invalid(conn)

  def update(conn, %{"token" => token, "password" => password}) do
    case Auth.reset_user_password(token, password) do
      {:ok, _user} ->
        page(conn, :done)

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(:unprocessable_entity) |> page(:form, token: token, too_short: true)

      {:error, _invalid_or_expired} ->
        invalid(conn)
    end
  end

  def update(conn, _params), do: invalid(conn)

  defp invalid(conn), do: conn |> put_status(:not_found) |> page(:invalid)

  defp page(conn, state, assigns \\ []) do
    copy = ResetPasswordPageHTML.copy(language(conn))
    static_origin = PidroServerWeb.Endpoint.static_url()

    csp =
      Enum.join(
        [
          "default-src 'self'",
          "img-src 'self' data: #{static_origin}",
          "style-src 'self' #{static_origin}",
          "script-src 'self' #{static_origin}",
          "object-src 'none'",
          "base-uri 'none'",
          "form-action 'self'",
          "frame-ancestors 'none'"
        ],
        "; "
      )

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("vary", "Accept-Language")
    |> put_resp_header("x-robots-tag", "noindex")
    |> put_resp_header("content-security-policy", csp)
    |> render(
      :show,
      [
        state: state,
        copy: copy,
        page:
          Map.merge(InvitePage.store_links(), %{
            title: copy.title,
            description: copy.description,
            canonical_url: nil
          }),
        crawler?: false,
        token: nil,
        too_short: false
      ] ++ assigns
    )
  end

  # Swedish when the browser lists Swedish before English, else English.
  defp language(conn) do
    conn
    |> get_req_header("accept-language")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.find_value(:en, fn tag ->
      case tag |> String.trim() |> String.downcase() do
        "sv" <> _ -> :sv
        "en" <> _ -> :en
        _other -> nil
      end
    end)
  end
end
