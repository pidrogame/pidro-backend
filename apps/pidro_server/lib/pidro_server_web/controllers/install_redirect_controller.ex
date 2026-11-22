defmodule PidroServerWeb.InstallRedirectController do
  @moduledoc """
  `/get`: the install link the app shares. A plain 302 by device to wherever
  `PidroServerWeb.InvitePage.install_target/1` says, so switch day moves every
  build's shared link at once.
  """

  use PidroServerWeb, :controller

  alias PidroServerWeb.InvitePage
  alias PidroServerWeb.InvitePage.UserAgent

  @doc "Redirects to the right install for the requesting device."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    device = conn |> get_req_header("user-agent") |> List.first() |> UserAgent.classify()

    # Always a 302 and never cached: a cached answer would outlive switch day.
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("vary", "User-Agent")
    |> redirect(external: InvitePage.install_target(device))
  end
end
