defmodule PidroServer.NewsTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.AccountsFixtures
  alias PidroServer.Feedback
  alias PidroServer.News
  alias PidroServer.News.Post

  describe "pop-ups" do
    setup :clear

    test "selects the newest eligible post and receipts are per player, not feed reads" do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.guest_fixture()
      {:ok, older} = News.create(%{title_en: "Older", body_en: "Hello", show_as_popup: true})
      {:ok, older} = News.publish(older)
      {:ok, newer} = News.create(%{title_en: "Newer", body_en: "Hello", show_as_popup: true})
      {:ok, newer} = News.publish(newer)
      {:ok, _draft} = News.create(%{title_en: "Draft", body_en: "x", show_as_popup: true})
      {:ok, off} = News.create(%{title_en: "Feed only", body_en: "x"})
      {:ok, _} = News.publish(off)

      assert News.popup(user, "en", nil, nil).id == newer.id
      :ok = News.mark_seen(user)
      assert News.popup(Repo.reload!(user), "en", nil, nil).id == newer.id
      assert :ok = News.mark_popup_seen(user, newer.id)
      assert :ok = News.mark_popup_seen(user, newer.id)
      assert News.popup(Repo.reload!(user), "en", nil, nil).id == older.id
      assert News.popup(other, "en", nil, nil).id == newer.id
      assert :ok = News.mark_popup_seen(user, older.id)
      assert News.popup(user, "en", nil, nil) == nil
      assert News.mark_popup_seen(user, off.id) == {:error, :not_found}
    end

    test "app updates require a known platform and a version strictly below its threshold" do
      user = AccountsFixtures.user_fixture()

      {:ok, post} =
        News.create(%{
          title_en: "Update",
          body_en: "x",
          show_as_popup: true,
          app_update: true,
          show_below_android: "3.2.10",
          show_below_ios: "3.3.0"
        })

      {:ok, post} = News.publish(post)

      for {platform, version, eligible} <- [
            {"android", "3.2.9", true},
            {"android", "3.2.10", false},
            {"android", "3.2.11", false},
            {"ios", "3.2.10", true},
            {"ios", "3.3.0", false},
            {"web", "1.0.0", false},
            {nil, nil, false},
            {"android", "garbage", false},
            {"android", nil, false}
          ] do
        assert News.popup(user, "en", platform, version) != nil == eligible,
               "#{inspect({platform, version})}"
      end

      {:ok, _} = News.update(post, %{show_below_android: ""})
      assert News.popup(user, "en", "android", "1.0.0") == nil
      assert News.popup(user, "en", "ios", "3.2.9").id == post.id
    end

    test "a build beside the version nudges that version's older builds and builds that send none" do
      user = AccountsFixtures.user_fixture()

      {:ok, post} =
        News.create(%{
          title_en: "Update to 3.3.0 (19)",
          body_en: "x",
          show_as_popup: true,
          app_update: true,
          show_below_ios: "3.3.0",
          show_below_ios_build: "19",
          show_below_android: "3.3.0",
          show_below_android_build: "15"
        })

      {:ok, post} = News.publish(post)

      for {platform, version, build, eligible} <- [
            {"ios", "3.3.0", nil, true},
            {"ios", "3.3.0", "14", true},
            {"ios", "3.3.0", "19", false},
            {"ios", "3.3.0", "20", false},
            {"ios", "3.3.1", nil, false},
            {"ios", "3.2.4", nil, true},
            {"ios", "3.2.4", "99", true},
            {"ios", "3.3.0", "", false},
            {"ios", "3.3.0", "14x", false},
            {"ios", "3.3.1", "1", false},
            {"android", "3.3.0", nil, true},
            {"android", "3.3.0", "11", true},
            {"android", "3.3.0", "15", false},
            {"android", "3.3.0", "9", true}
          ] do
        assert News.popup(user, "en", platform, version, build) != nil == eligible,
               "#{inspect({platform, version, build})}"
      end

      # Without a build on the post, the same version is not below it.
      {:ok, _} = News.update(post, %{show_below_ios_build: ""})
      assert News.popup(user, "en", "ios", "3.3.0") == nil
      assert News.popup(user, "en", "ios", "3.3.0", "14") == nil
      assert News.popup(user, "en", "ios", "3.2.4", "14").id == post.id

      policy = News.native_update_policy()
      assert policy.minimum_native_versions == %{"android" => "3.3.0", "ios" => "3.3.0"}
      assert policy.minimum_native_builds == %{"android" => "15"}

      :ok = News.mark_popup_seen(user, post.id)

      for {platform, version, build} <- [
            {"ios", "3.2.4", nil},
            {"android", "3.3.0", nil},
            {"android", "3.3.0", "11"}
          ] do
        assert News.popup(user, "en", platform, version, build) == nil,
               "#{inspect({platform, version, build})}"
      end
    end

    test "a minimum build is digits and needs its version" do
      base = %{title_en: "Update", body_en: "x", app_update: true}

      assert {:error, changeset} =
               News.create(
                 Map.merge(base, %{show_below_ios: "3.3.0", show_below_ios_build: "15a"})
               )

      assert %{show_below_ios_build: ["must be a build number like 15"]} = errors_on(changeset)

      assert {:error, changeset} = News.create(Map.put(base, :show_below_android_build, "12"))
      assert %{show_below_android_build: ["needs a version beside it"]} = errors_on(changeset)

      assert {:ok, %{show_below_ios_build: "15"}} =
               News.create(
                 Map.merge(base, %{show_below_ios: "3.3.0", show_below_ios_build: "15"})
               )
    end

    test "stores Markdown verbatim and localizes optional fields with English fallback" do
      body = "Cards are **bigger**.\n[Read more](https://pidro.com)"

      {:ok, post} =
        News.create(%{
          title_en: "Cards",
          body_en: body,
          eyebrow_en: "New",
          eyebrow_sv: "Nytt",
          button_label_en: "Read",
          button_url: "https://pidro.com"
        })

      shown = News.localize(Repo.reload!(post), "sv")
      assert shown.body == body
      assert shown.eyebrow == "Nytt"
      assert shown.button_label == "Read"
      assert shown.button_url == "https://pidro.com"

      assert {:error, changeset} =
               News.update(post, %{show_below_ios: "3.2", button_url: "javascript:alert(1)"})

      assert %{show_below_ios: [_], button_url: [_]} = errors_on(changeset)

      {:ok, update} = News.update(post, %{app_update: true})
      assert %{button_label: nil, button_url: nil} = News.localize(update, "sv")
    end
  end

  describe "the seeded posts" do
    test "the welcome note is published and the two 3.2.3 notes are drafts" do
      assert [
               %Post{title_en: "The table sounds like Pidro again", published_at: nil},
               %Post{title_en: "Bigger cards, a calmer table", published_at: nil},
               %Post{title_en: "Welcome to the new Pidro", title_sv: "Välkommen till nya Pidro"} =
                 welcome
             ] = News.list_all() |> Enum.sort_by(&{&1.published_at != nil, &1.id})

      assert welcome.published_at == ~U[2026-10-26 08:00:00Z]
      assert welcome.body_en =~ "still being built.\nHere today: Finnish and Louisiana rules"
      assert welcome.body_sv =~ "Där ändras ingenting."
    end
  end

  describe "list_published/2" do
    setup :clear

    test "lists published posts newest first in the player's language, never drafts" do
      old = post!("Old", "Gammal", ~U[2026-10-01 10:00:00Z])
      new = post!("New", "Ny", ~U[2026-11-01 10:00:00Z])
      _draft = post!("Draft", "Utkast", nil)

      assert News.list_published("en", 30) == [
               %{
                 id: new.id,
                 title: "New",
                 body: "New body",
                 published_at: new.published_at,
                 eyebrow: nil,
                 image_url: nil,
                 button_label: nil,
                 button_url: nil,
                 show_as_popup: false,
                 app_update: false,
                 show_below_android: nil,
                 show_below_ios: nil,
                 show_below_android_build: nil,
                 show_below_ios_build: nil
               },
               %{
                 id: old.id,
                 title: "Old",
                 body: "Old body",
                 published_at: old.published_at,
                 eyebrow: nil,
                 image_url: nil,
                 button_label: nil,
                 button_url: nil,
                 show_as_popup: false,
                 app_update: false,
                 show_below_android: nil,
                 show_below_ios: nil,
                 show_below_android_build: nil,
                 show_below_ios_build: nil
               }
             ]

      assert [%{title: "Ny", body: "Ny body"}, %{title: "Gammal"}] =
               News.list_published("sv", 30)

      assert [%{title: "New"}] = News.list_published("en", 1)
    end

    test "Swedish falls back to English one field at a time" do
      {:ok, only_title} =
        News.create(%{title_en: "Cards", body_en: "Bigger cards", title_sv: "Kort", body_sv: ""})

      {:ok, only_body} = News.create(%{title_en: "Sound", body_en: "Hear it", body_sv: "Hör det"})
      {:ok, _} = News.publish(only_title)
      {:ok, _} = News.publish(only_body)

      assert Enum.sort(Enum.map(News.list_published("sv", 30), &{&1.title, &1.body})) ==
               [{"Kort", "Bigger cards"}, {"Sound", "Hör det"}]
    end
  end

  describe "unread_count/1 and mark_seen/1" do
    setup :clear

    test "every published post is new before the first look, none after it" do
      user = AccountsFixtures.user_fixture()
      post!("One", nil, ~U[2026-10-01 10:00:00Z])
      post!("Two", nil, ~U[2026-11-01 10:00:00Z])
      post!("Draft", nil, nil)

      assert user.news_seen_at == nil
      assert News.unread_count(user) == 2

      assert :ok = News.mark_seen(user)
      user = Repo.reload!(user)
      assert News.unread_count(user) == 0

      {:ok, later} = News.create(%{title_en: "Three", body_en: "x"})
      {:ok, _} = News.publish(later)
      assert News.unread_count(user) == 1
    end

    test "a post published after the last look is the only one counted" do
      user = AccountsFixtures.user_fixture()
      post!("Before", nil, ~U[2026-10-01 10:00:00Z])
      post!("After", nil, ~U[2026-11-02 10:00:00Z])

      user =
        user |> Ecto.Changeset.change(news_seen_at: ~U[2026-11-01 00:00:00Z]) |> Repo.update!()

      assert News.unread_count(user) == 1
    end
  end

  describe "admin" do
    setup :clear

    test "publish sets the date once, unpublish takes it back to a draft" do
      {:ok, draft} = News.create(%{title_en: "Hi", body_en: "Hello"})
      assert draft.published_at == nil

      {:ok, published} = News.publish(draft)
      assert DateTime.diff(DateTime.utc_now(), published.published_at) in 0..5
      assert News.publish(published) == {:error, :published}

      {:ok, unpublished} = News.unpublish(published)
      assert unpublished.published_at == nil
      assert News.list_published("en", 30) == []
    end

    test "only drafts are deleted; a note keeps its words when its post goes" do
      {:ok, post} = News.create(%{title_en: "Hi", body_en: "Hello"})
      {:ok, published} = News.publish(post)
      assert News.delete(published) == {:error, :published}
      assert Repo.get(Post, post.id)

      {:ok, note} =
        Feedback.create(%{"kind" => "note", "body" => "Nice", "news_post_id" => post.id}, nil)

      assert [%Post{answers: 1}] = News.list_all()

      {:ok, draft} = News.unpublish(published)
      assert {:ok, _} = News.delete(draft)
      assert Repo.get(Post, post.id) == nil
      assert %{news_post_id: nil, body: "Nice"} = Repo.reload!(note)
    end

    test "lists drafts first, then published newest first, and needs English" do
      old = post!("Old", nil, ~U[2026-10-01 10:00:00Z])
      new = post!("New", nil, ~U[2026-11-01 10:00:00Z])
      draft = post!("Draft", nil, nil)

      assert Enum.map(News.list_all(), & &1.id) == [draft.id, new.id, old.id]

      assert {:error, changeset} = News.create(%{title_sv: "Bara svenska"})
      assert %{title_en: ["can't be blank"], body_en: ["can't be blank"]} = errors_on(changeset)
    end
  end

  defp clear(_context) do
    Repo.delete_all(Post)
    :ok
  end

  defp post!(title, title_sv, published_at) do
    Repo.insert!(%Post{
      title_en: title,
      body_en: "#{title} body",
      title_sv: title_sv,
      body_sv: title_sv && "#{title_sv} body",
      published_at: published_at
    })
  end
end
