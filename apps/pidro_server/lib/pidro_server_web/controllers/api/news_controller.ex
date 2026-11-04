defmodule PidroServerWeb.API.NewsController do
  @moduledoc """
  News for the app's Home (PID-346): the latest published posts in the
  player's language, how many are new, and the mark that they were seen.
  The server keeps no language per player, so the app names it in `locale`.
  """

  use PidroServerWeb, :controller

  alias PidroServer.News

  def index(conn, params) do
    user = conn.assigns.current_user
    locale = if params["locale"] == "sv", do: "sv", else: "en"

    json(conn, %{
      data: %{posts: News.list_published(locale, 30), unread: News.unread_count(user)}
    })
  end

  def seen(conn, _params) do
    :ok = News.mark_seen(conn.assigns.current_user)
    send_resp(conn, :no_content, "")
  end
end
