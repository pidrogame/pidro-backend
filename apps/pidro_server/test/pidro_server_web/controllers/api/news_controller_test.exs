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
                     "published_at" => "2026-10-26T08:00:00Z",
                     "eyebrow" => nil,
                     "image_url" => nil,
                     "button_label" => nil,
                     "button_url" => nil,
                     "show_as_popup" => false,
                     "app_update" => false,
                     "show_below_android" => nil,
                     "show_below_ios" => nil,
                     "show_below_android_build" => nil,
                     "show_below_ios_build" => nil
                   }
                 ],
                 "unread" => 1,
                 "popup" => nil
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

  test "popup acknowledgement survives another device, never marks the feed read", %{
    welcome: welcome
  } do
    alias PidroServer.News
    user = AccountsFixtures.guest_fixture()

    {:ok, welcome} =
      News.update(welcome, %{
        show_as_popup: true,
        app_update: true,
        show_below_android: "3.2.10",
        eyebrow_en: "New in Pidro",
        body_en: "**Hello**\nAgain"
      })

    url = "/api/v1/news?locale=sv&platform=android&app_version=3.2.9"
    data = build_conn() |> auth(user) |> get(url) |> json_response(200) |> Map.fetch!("data")

    assert %{
             "id" => id,
             "title" => "Välkommen",
             "eyebrow" => "New in Pidro",
             "body" => "**Hello**\nAgain"
           } = data["popup"]

    assert id == welcome.id
    assert data["unread"] == 1

    for _ <- 1..2 do
      assert build_conn() |> auth(user) |> post(~p"/api/v1/news/#{id}/seen") |> response(204) ==
               ""
    end

    data =
      build_conn()
      |> auth(Repo.reload!(user))
      |> get(url)
      |> json_response(200)
      |> Map.fetch!("data")

    assert %{"popup" => nil, "unread" => 1, "posts" => [_]} = data
    other = AccountsFixtures.user_fixture()

    assert build_conn()
           |> auth(other)
           |> get(url)
           |> json_response(200)
           |> get_in(["data", "popup", "id"]) == id

    for bad_id <- ["0", "missing", "999999999999999999999999999999"] do
      assert build_conn() |> auth(user) |> post("/api/v1/news/#{bad_id}/seen") |> response(404) ==
               ""
    end

    {:ok, _} = News.unpublish(welcome)
    assert build_conn() |> auth(user) |> post(~p"/api/v1/news/#{id}/seen") |> response(404) == ""
    assert build_conn() |> post(~p"/api/v1/news/#{id}/seen") |> response(401)
  end

  test "app_build picks the pop-up for a same-version older build; an app without it is older",
       %{welcome: welcome} do
    {:ok, _} =
      PidroServer.News.update(welcome, %{
        show_as_popup: true,
        app_update: true,
        show_below_android: "3.3.0",
        show_below_android_build: "12"
      })

    popup = fn query ->
      build_conn()
      |> auth(AccountsFixtures.guest_fixture())
      |> get("/api/v1/news?locale=en&platform=android&" <> query)
      |> json_response(200)
      |> get_in(["data", "popup"])
    end

    assert %{"show_below_android" => "3.3.0", "show_below_android_build" => "12"} =
             popup.("app_version=3.3.0&app_build=11")

    assert popup.("app_version=3.3.0&app_build=12") == nil
    assert %{"show_below_android_build" => "12"} = popup.("app_version=3.3.0")
    assert popup.("app_version=3.2.4") != nil
  end

  defp auth(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")
end
