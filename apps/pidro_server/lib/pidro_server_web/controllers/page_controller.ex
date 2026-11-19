defmodule PidroServerWeb.PageController do
  use PidroServerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def legacy_leagues(conn, _params), do: redirect(conn, to: ~p"/admin/leagues")
end
