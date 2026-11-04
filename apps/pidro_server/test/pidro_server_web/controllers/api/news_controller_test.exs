defmodule PidroServerWeb.API.NewsControllerTest do
  use PidroServerWeb.ConnCase, async: true

  alias PidroServer.Accounts.Token
  alias PidroServer.Accounts.User
  alias PidroServer.AccountsFixtures
  alias PidroServer.News.Post
  alias PidroServer.Repo

  setup do
    Repo.delete_all(Post)

    welcome =
      Repo.insert!(%Post{
        title_en: "Welcome",
        body_en: "Line one\nLine two",
        title_sv: "Välkommen",
        published_at: ~U[2026-10-26 08:00:00Z]
      })

    Repo.insert!(%Post{title_en: "Draft", body_en: "Not yet"})
    %{welcome: welcome}
  end

  describe "GET /api/v1/news" do
    test "a player reads published posts in English, all unread", %{conn: conn, welcome: welcome} do
      conn = conn |> auth(AccountsFixtures.user_fixture()) |> get(~p"/api/v1/news")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "posts" => [
                   %{
                     "id" => welcome.id,
                     "title" => "Welcome",
                     "body" => "Line one\nLine two",
                     "published_at" => "2026-10-26T08:00:00Z"
                   }
                 ],
                 "unread" => 1
               }
             }
    end

    test "a guest reads them in Swedish, the body falling back to English", %{conn: conn} do
      conn = conn |> auth(AccountsFixtures.guest_fixture()) |> get(~p"/api/v1/news?locale=sv")

      assert %{"posts" => [%{"title" => "Välkommen", "body" => "Line one\nLine two"}]} =
               json_response(conn, 200)["data"]
    end

    test "lists the latest 30, all of them unread", %{conn: conn} do
      for day <- 1..31 do
        Repo.insert!(%Post{
          title_en: "Day #{day}",
          body_en: "x",
          published_at: DateTime.add(~U[2026-09-01 10:00:00Z], day, :day)
        })
      end

      conn = conn |> auth(AccountsFixtures.user_fixture()) |> get(~p"/api/v1/news")
      %{"posts" => posts, "unread" => 32} = json_response(conn, 200)["data"]

      assert length(posts) == 30
      assert hd(posts)["title"] == "Welcome"
      assert List.last(posts)["title"] == "Day 3"
    end

    test "an unknown locale reads English", %{conn: conn} do
      conn = conn |> auth(AccountsFixtures.user_fixture()) |> get(~p"/api/v1/news?locale=fi")
      assert [%{"title" => "Welcome"}] = json_response(conn, 200)["data"]["posts"]
    end

    test "needs a token", %{conn: conn} do
      assert get(conn, ~p"/api/v1/news").status == 401
      assert post(build_conn(), ~p"/api/v1/news/seen").status == 401
    end
  end

  describe "POST /api/v1/news/seen" do
    test "marks the posts seen, so nothing is unread until the next one", %{conn: conn} do
      guest = AccountsFixtures.guest_fixture()

      conn = conn |> auth(guest) |> post(~p"/api/v1/news/seen")
      assert response(conn, 204) == ""
      assert %User{news_seen_at: %DateTime{}} = Repo.get!(User, guest.id)

      conn = build_conn() |> auth(guest) |> get(~p"/api/v1/news")
      assert %{"unread" => 0, "posts" => [_]} = json_response(conn, 200)["data"]
    end
  end

  defp auth(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")
end
