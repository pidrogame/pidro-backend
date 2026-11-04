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
    view |> element("button[phx-value-locale=sv]") |> render_click()
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

  describe "Translate to Swedish" do
    test "fills both Swedish fields from the answer and saves nothing", %{conn: conn} do
      Req.Test.stub(PidroServer.Translate, fn conn ->
        Req.Test.json(conn, %{
          "stop_reason" => "end_turn",
          "content" => [
            %{"type" => "thinking", "thinking" => "Casual, short.", "signature" => "sig"},
            %{"type" => "text", "text" => ~s({"title":"Hej alla","body":"Rad ett\\nRad två"})}
          ]
        })
      end)

      {:ok, view, _html} = live(conn, ~p"/admin/news")
      view |> element("button", "New post") |> render_click()

      view
      |> form("#news-form", post: %{title_en: "Hello all", body_en: "Line one\nLine two"})
      |> render_change()

      refute has_element?(view, "#translate[data-confirm]")
      assert view |> element("#translate") |> render_click() =~ "Translating…"

      render_async(view)
      assert has_element?(view, "#post_title_sv[value='Hej alla']")
      assert view |> element("#post_body_sv") |> render() =~ "Rad ett\nRad två"
      assert has_element?(view, "#post_title_en[value='Hello all']")
      refute has_element?(view, "#translate-error")
      assert Repo.get_by(Post, title_en: "Hello all") == nil
    end

    test "asks before replacing Swedish that is already there", %{conn: conn} do
      cards = Repo.get_by!(Post, title_en: "Bigger cards, a calmer table")
      {:ok, view, _html} = live(conn, ~p"/admin/news")
      view |> element("#post-#{cards.id} button", "Edit") |> render_click()

      assert has_element?(
               view,
               "#translate[data-confirm='Replace the Swedish text with a new translation?']"
             )

      view |> form("#news-form", post: %{title_sv: "", body_sv: ""}) |> render_change()
      refute has_element?(view, "#translate[data-confirm]")
    end

    test "an API error says so in one line and leaves the Swedish alone", %{conn: conn} do
      Req.Test.stub(PidroServer.Translate, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"type" => "error"})
      end)

      cards = Repo.get_by!(Post, title_en: "Bigger cards, a calmer table")
      {:ok, view, _html} = live(conn, ~p"/admin/news")
      view |> element("#post-#{cards.id} button", "Edit") |> render_click()

      ExUnit.CaptureLog.capture_log(fn ->
        view |> element("#translate") |> render_click()
        render_async(view)
      end)

      assert view |> element("#translate-error") |> render() =~ "Translation failed. Try again."
      assert has_element?(view, "#post_title_sv[value='Större kort, ett lugnare bord']")
      refute has_element?(view, "#translate[disabled]")
    end
  end
end

defmodule PidroServerWeb.Dev.NewsLiveNoKeyTest do
  # Changes the app's Translate config, so it runs apart from async tests.
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_admin

  test "without ANTHROPIC_API_KEY the button is off and says why", %{conn: conn} do
    config = Application.fetch_env!(:pidro_server, PidroServer.Translate)
    Application.put_env(:pidro_server, PidroServer.Translate, Keyword.put(config, :api_key, nil))
    on_exit(fn -> Application.put_env(:pidro_server, PidroServer.Translate, config) end)

    {:ok, view, _html} = live(conn, ~p"/admin/news")
    view |> element("button", "New post") |> render_click()
    view |> form("#news-form", post: %{title_en: "Hi", body_en: "Row"}) |> render_change()

    assert has_element?(view, "#translate[disabled]")

    assert view |> element("#translate-off") |> render() =~
             "Add ANTHROPIC_API_KEY to turn on translation."
  end
end
