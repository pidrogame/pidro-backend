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
      data: %{
        posts: News.list_published(locale, 30),
        unread: News.unread_count(user),
        popup: News.popup(user, locale, params["platform"], params["app_version"])
      }
    })
  end

  def popup_seen(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         :ok <- News.mark_popup_seen(conn.assigns.current_user, id) do
      send_resp(conn, :no_content, "")
    else
      _ -> send_resp(conn, :not_found, "")
    end
  end

  def image(conn, %{"id" => id, "version" => version}) do
    with {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 <- Integer.parse(id),
         bytes when is_binary(bytes) <- News.fetch_image(id, version) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("etag", ~s("#{version}"))
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "")
    end
  end

  def seen(conn, _params) do
    :ok = News.mark_seen(conn.assigns.current_user)
    send_resp(conn, :no_content, "")
  end
end
