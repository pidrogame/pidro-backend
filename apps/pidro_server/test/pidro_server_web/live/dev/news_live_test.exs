defmodule PidroServerWeb.Dev.NewsLiveTest do
  use PidroServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PidroServer.Feedback
  alias PidroServer.News.Post
  alias PidroServer.Repo

  setup :register_and_log_in_admin

  test "lists the seeded posts, drafts first, with their answers", %{conn: conn} do
    welcome = Repo.get_by!(Post, title_en: "Welcome to the new Pidro")

    {:ok, _} =
      Feedback.create(%{"kind" => "note", "body" => "Hej", "news_post_id" => welcome.id}, nil)

    {:ok, view, _html} = live(conn, ~p"/admin/news")

    titles =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#news-posts article p.font-semibold")
      |> Enum.map(&LazyHTML.text/1)

    assert titles == [
             "Bigger cards, a calmer table",
             "The table sounds like Pidro again",
             "Welcome to the new Pidro"
           ]

    row = view |> element("#post-#{welcome.id}") |> render()
    assert row =~ "Published 2026-10-26 08:00 UTC"
    assert row =~ "Unpublish"
    refute row =~ "Delete"

    assert has_element?(
             view,
             "#post-#{welcome.id} a[href='/admin/feedback?status=all']",
             "1 answer"
           )
  end

  test "writes, previews in both languages, publishes and deletes a post", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/news")

    view |> element("button", "New post") |> render_click()

    view
    |> form("#news-form",
      post: %{title_en: "Hello", body_en: "One\nTwo", title_sv: "Hej", body_sv: ""}
    )
    |> render_change()

    assert view |> element("#news-preview") |> render() =~ "Hello"
    view |> element("button", "Swedish") |> render_click()
    preview = view |> element("#news-preview") |> render()
    assert preview =~ "Hej"
    assert preview =~ "One\nTwo"

    view |> form("#news-form", post: %{title_en: ""}) |> render_submit()
    assert has_element?(view, "#news-form", "can't be blank")

    view
    |> form("#news-form", post: %{title_en: "Hello", body_en: "One\nTwo", title_sv: "Hej"})
    |> render_submit()

    post = Repo.get_by!(Post, title_en: "Hello")
    assert %Post{title_sv: "Hej", body_sv: nil, published_at: nil} = post

    assert has_element?(view, "#post-#{post.id} button[data-confirm]", "Publish")
    view |> element("#post-#{post.id} button", "Publish") |> render_click()
    assert %Post{published_at: %DateTime{}} = Repo.reload!(post)
    refute has_element?(view, "#post-#{post.id} button", "Delete")

    view |> element("#post-#{post.id} button", "Unpublish") |> render_click()
    view |> element("#post-#{post.id} button", "Delete") |> render_click()
    refute has_element?(view, "#post-#{post.id}")
    refute has_element?(view, "#news-editor")
    assert Repo.get(Post, post.id) == nil
  end

  test "a published post is never deleted", %{conn: conn} do
    welcome = Repo.get_by!(Post, title_en: "Welcome to the new Pidro")
    {:ok, view, _html} = live(conn, ~p"/admin/news")

    assert render_click(view, "delete", %{"id" => "#{welcome.id}"}) =~ "That post is published."
    assert Repo.reload!(welcome)
  end

  test "a note about a post says so in /admin/feedback", %{conn: conn} do
    welcome = Repo.get_by!(Post, title_en: "Welcome to the new Pidro")

    {:ok, note} =
      Feedback.create(%{"kind" => "note", "body" => "Tack", "news_post_id" => welcome.id}, nil)

    {:ok, other} = Feedback.create(%{"kind" => "note", "body" => "Hm"}, nil)

    {:ok, view, _html} = live(conn, ~p"/admin/feedback")

    assert view |> element("#note-#{note.id}") |> render() =~
             "About the post: Welcome to the new Pidro"

    refute view |> element("#note-#{other.id}") |> render() =~ "About the post"
  end
end
