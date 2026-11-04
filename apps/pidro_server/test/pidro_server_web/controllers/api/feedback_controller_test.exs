defmodule PidroServerWeb.API.FeedbackControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import Swoosh.TestAssertions

  alias PidroServer.Accounts.Token
  alias PidroServer.AccountsFixtures
  alias PidroServer.Feedback.Entry
  alias PidroServer.News.Post
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats

  defmodule ErrorMailer do
    use Swoosh.Adapter
    def deliver(_email, _config), do: {:error, :provider_down}
  end

  @details %{
    "app_version" => "1.4.0",
    "native_build" => "88",
    "update_id" => "u-1",
    "channel" => "beta",
    "platform" => "ios",
    "os_version" => "26.1",
    "device_model" => "iPhone 17"
  }
  @note %{
    "kind" => "note",
    "body" => "Trumps are hard to see\nin dark mode",
    "details" => @details
  }

  setup do
    user = AccountsFixtures.user_fixture(%{display_name: "Aino"})
    other = AccountsFixtures.user_fixture()

    game =
      Repo.insert!(%GameStats{
        room_code: "FDBK",
        rule_set: "louisiana",
        completed_at: DateTime.utc_now(:second),
        player_ids: [user.id, other.id]
      })

    %{user: user, game: game}
  end

  describe "POST /api/v1/feedback" do
    test "a signed-in note is saved and mailed with the player's address as reply-to",
         %{conn: conn, user: user, game: game} do
      conn = conn |> auth(user) |> post(~p"/api/v1/feedback", @note)

      assert %{"data" => %{"id" => id}} = json_response(conn, 201)
      assert %Entry{kind: "note", game_id: game_id, rule_set: "louisiana"} = Repo.get!(Entry, id)
      assert game_id == game.id

      assert_email_sent(fn email ->
        assert email.to == [{"", "marcel@pidro.online"}]
        assert email.reply_to == {"", user.email}
        assert email.subject == "Pidro ##{id}: Trumps are hard to see in dark mode"
        assert email.text_body =~ ~r/\ATrumps are hard to see\nin dark mode\n/
        assert email.text_body =~ "Feedback ##{id}"
        assert email.text_body =~ "Player: Aino (#{user.id})"
        assert email.text_body =~ "Reply to: #{user.email}"
        assert email.text_body =~ "App: 1.4.0 (build 88, update u-1, beta)"
        assert email.text_body =~ "Device: ios 26.1, iPhone 17"
        assert email.text_body =~ "Last game: #{game.id} (louisiana)"
        assert email.text_body =~ "/admin/feedback"
      end)
    end

    test "without a token a note answers 401, saves nothing and mails no one", %{conn: conn} do
      for params <- [@note, %{"kind" => "pace", "answer" => "right"}] do
        conn = post(conn, ~p"/api/v1/feedback", params)
        assert %{"error_code" => "unauthorized"} = json_response(conn, 401)
      end

      assert Repo.aggregate(Entry, :count) == 0
      assert_no_email_sent()
    end

    test "a guest's note answers 403 ACCOUNT_REQUIRED, saves nothing and mails no one",
         %{conn: conn} do
      guest = AccountsFixtures.guest_fixture()
      note = Map.put(@note, "reply_email", "crawlerrobo@gmail.com")

      for params <- [note, %{"kind" => "pace", "answer" => "right"}] do
        conn = conn |> auth(guest) |> post(~p"/api/v1/feedback", params)

        assert %{
                 "errors" => [%{"code" => "ACCOUNT_REQUIRED"}],
                 "error_code" => "account_required"
               } =
                 json_response(conn, 403)
      end

      assert Repo.aggregate(Entry, :count) == 0
      assert_no_email_sent()
    end

    test "a note written back to a news post names it; a draft's, unknown or bad id is dropped",
         %{conn: conn, user: user} do
      news =
        Repo.insert!(%Post{
          title_en: "Bigger cards",
          body_en: "x",
          published_at: ~U[2026-11-01 10:00:00Z]
        })

      note = Map.put(@note, "news_post_id", news.id)

      conn = conn |> auth(user) |> post(~p"/api/v1/feedback", note)
      assert %{"data" => %{"id" => id}} = json_response(conn, 201)
      assert %Entry{news_post_id: post_id} = Repo.get!(Entry, id)
      assert post_id == news.id

      assert_email_sent(fn email ->
        assert email.subject ==
                 "Re: Bigger cards · Pidro ##{id}: Trumps are hard to see in dark mode"
      end)

      draft = Repo.insert!(%Post{title_en: "Not out yet", body_en: "x"})

      for bad <- [
            draft.id,
            news.id + 1_000,
            "#{news.id}",
            -1,
            99_999_999_999_999_999_999,
            %{"a" => 1}
          ] do
        conn =
          build_conn()
          |> auth(user)
          |> post(~p"/api/v1/feedback", %{note | "news_post_id" => bad})

        assert %{"data" => %{"id" => id}} = json_response(conn, 201)
        assert %Entry{news_post_id: nil} = Repo.get!(Entry, id)
        assert_email_sent(fn email -> assert email.subject =~ ~r/\APidro #/ end)
      end

      conn = build_conn() |> auth(user) |> post(~p"/api/v1/feedback", @note)
      assert %{"data" => %{"id" => id}} = json_response(conn, 201)
      assert %Entry{news_post_id: nil} = Repo.get!(Entry, id)

      conn =
        build_conn()
        |> auth(user)
        |> post(~p"/api/v1/feedback", %{
          "kind" => "pace",
          "answer" => "right",
          "news_post_id" => news.id
        })

      assert %{"data" => %{"id" => id}} = json_response(conn, 201)
      assert %Entry{news_post_id: nil} = Repo.get!(Entry, id)
    end

    test "a note with null details is saved", %{conn: conn, user: user} do
      conn =
        conn
        |> auth(user)
        |> post(~p"/api/v1/feedback", %{"kind" => "note", "body" => "hi", "details" => nil})

      assert %{"data" => %{"id" => id}} = json_response(conn, 201)
      assert %Entry{details: %{}} = Repo.get!(Entry, id)
    end

    test "a failed mail still answers 201 and keeps the note", %{conn: conn, user: user} do
      mailer_env = Application.fetch_env!(:pidro_server, PidroServer.Mailer)
      Application.put_env(:pidro_server, PidroServer.Mailer, adapter: ErrorMailer)
      on_exit(fn -> Application.put_env(:pidro_server, PidroServer.Mailer, mailer_env) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = conn |> auth(user) |> post(~p"/api/v1/feedback", @note)
          assert %{"data" => %{"id" => id}} = json_response(conn, 201)
          assert %Entry{body: "Trumps are hard to see\nin dark mode"} = Repo.get!(Entry, id)
        end)

      assert log =~ "Feedback email delivery failed"
      refute log =~ "dark mode"
    end

    test "pace and old-Pidro answers are saved without a mail", %{user: user, game: game} do
      for {kind, answer} <- [{"pace", "too_slow"}, {"old_pidro", "same"}, {"pace", "skipped"}] do
        conn =
          build_conn()
          |> auth(user)
          |> post(~p"/api/v1/feedback", %{
            "kind" => kind,
            "answer" => answer,
            "game_id" => game.id
          })

        assert %{"data" => %{"id" => id}} = json_response(conn, 201)
        assert %Entry{kind: ^kind, answer: ^answer, rule_set: "louisiana"} = Repo.get!(Entry, id)
      end

      assert_no_email_sent()
    end

    test "bad input answers 422", %{conn: conn, user: user} do
      conn =
        conn |> auth(user) |> post(~p"/api/v1/feedback", %{"kind" => "pace", "answer" => "meh"})

      assert [%{"code" => "answer"}] = json_response(conn, 422)["errors"]

      conn =
        build_conn()
        |> auth(user)
        |> post(~p"/api/v1/feedback", %{"kind" => "note", "body" => ""})

      assert [%{"code" => "body"}] = json_response(conn, 422)["errors"]

      conn = build_conn() |> auth(user) |> post(~p"/api/v1/feedback", %{"body" => "no kind"})
      assert [%{"code" => "kind"}] = json_response(conn, 422)["errors"]
      assert_no_email_sent()
    end

    test "notes are limited by address; answers still go through", %{conn: conn, user: user} do
      with_limit(:feedback_note, 1, 3_600_000)

      assert conn |> auth(user) |> post(~p"/api/v1/feedback", @note) |> Map.get(:status) == 201

      conn =
        build_conn() |> auth(AccountsFixtures.user_fixture()) |> post(~p"/api/v1/feedback", @note)

      assert [%{"code" => "RATE_LIMITED"}] = json_response(conn, 429)["errors"]

      for _ <- 1..3 do
        conn =
          build_conn()
          |> auth(user)
          |> post(~p"/api/v1/feedback", %{"kind" => "pace", "answer" => "right"})

        assert conn.status == 201
      end

      assert Repo.aggregate(Entry, :count) == 4
    end

    test "answers have their own limit, which notes do not use", %{conn: conn, user: user} do
      with_limit(:feedback_answer, 1, 3_600_000)

      assert conn |> auth(user) |> post(~p"/api/v1/feedback", @note) |> Map.get(:status) == 201
      answer = %{"kind" => "pace", "answer" => "right"}

      assert build_conn() |> auth(user) |> post(~p"/api/v1/feedback", answer) |> Map.get(:status) ==
               201

      conn = build_conn() |> auth(user) |> post(~p"/api/v1/feedback", answer)
      assert [%{"code" => "RATE_LIMITED"}] = json_response(conn, 429)["errors"]
    end

    test "notes are limited per player across addresses", %{conn: conn, user: user} do
      with_limit(:feedback_note_user, 1, 86_400_000)

      assert conn |> auth(user) |> post(~p"/api/v1/feedback", @note) |> Map.get(:status) == 201

      conn =
        build_conn()
        |> from_ip({198, 51, 100, 7})
        |> auth(user)
        |> post(~p"/api/v1/feedback", @note)

      assert json_response(conn, 429)
    end
  end

  describe "GET /api/v1/feedback/ask" do
    test "asks about the pace of the latest game with people", %{
      conn: conn,
      user: user,
      game: game
    } do
      assert conn |> auth(user) |> get(~p"/api/v1/feedback/ask") |> json_response(200) ==
               %{"data" => %{"ask" => "pace", "game_id" => game.id}}

      build_conn()
      |> auth(user)
      |> post(~p"/api/v1/feedback", %{"kind" => "pace", "answer" => "skipped"})

      assert build_conn() |> auth(user) |> get(~p"/api/v1/feedback/ask") |> json_response(200) ==
               %{"data" => %{"ask" => nil}}
    end

    test "needs a signed-in player", %{conn: conn} do
      assert get(conn, ~p"/api/v1/feedback/ask").status == 401
    end

    test "never asks a guest, even after a game with people", %{conn: conn, user: user} do
      guest = AccountsFixtures.guest_fixture()

      Repo.insert!(%GameStats{
        room_code: "GST1",
        rule_set: "finnish",
        completed_at: DateTime.utc_now(:second),
        player_ids: [guest.id, user.id]
      })

      assert conn |> auth(guest) |> get(~p"/api/v1/feedback/ask") |> json_response(200) ==
               %{"data" => %{"ask" => nil}}
    end
  end

  defp auth(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")
end
