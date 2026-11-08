defmodule PidroServer.FeedbackTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.AccountsFixtures
  alias PidroServer.Feedback
  alias PidroServer.Feedback.Entry
  alias PidroServer.Stats.GameStats

  @now ~U[2026-11-01 00:30:00Z]

  setup do
    %{user: AccountsFixtures.user_fixture(), other: AccountsFixtures.user_fixture()}
  end

  describe "create/2" do
    test "a note takes the player's latest game, even one with bots only, and their email",
         %{user: user, other: other} do
      game([user.id, other.id], "louisiana", ~U[2026-10-30 10:00:00Z])
      latest = game([user.id], "finnish", ~U[2026-10-31 10:00:00Z])

      assert {:ok, entry} =
               Feedback.create(
                 %{
                   "kind" => "note",
                   "body" => "The bid button hides behind my thumb",
                   "game_id" => Ecto.UUID.generate(),
                   "rule_set" => "louisiana",
                   "details" => %{
                     "app_version" => "1.4.0",
                     "app_build" => "15",
                     "platform" => "ios",
                     "pin" => "1234"
                   }
                 },
                 user
               )

      assert %Entry{kind: "note", status: "open", user_id: user_id} = entry
      assert user_id == user.id
      assert {entry.game_id, entry.rule_set} == {latest.id, "finnish"}
      assert entry.reply_email == user.email

      assert entry.details == %{
               "app_version" => "1.4.0",
               "app_build" => "15",
               "platform" => "ios"
             }
    end

    test "a note keeps the address the player gave", %{user: user} do
      assert {:ok, %{reply_email: "other@example.com"}} =
               Feedback.create(note(%{"reply_email" => "other@example.com"}), user)
    end

    test "a guest note without an address has no game and no reply address" do
      assert {:ok, entry} = Feedback.create(note(), nil)

      assert {entry.user_id, entry.reply_email, entry.game_id, entry.rule_set} ==
               {nil, nil, nil, nil}
    end

    test "a note needs a body and a usable address" do
      assert {:error, changeset} = Feedback.create(note(%{"body" => "   "}), nil)
      assert %{body: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} = Feedback.create(note(%{"reply_email" => "a,b@c.de"}), nil)
      assert %{reply_email: [_]} = errors_on(changeset)
    end

    test "a pace answer takes the game it names when the player was in it",
         %{user: user, other: other} do
      named = game([user.id, other.id], "louisiana", ~U[2026-10-30 10:00:00Z])
      latest = game([user.id], "finnish", ~U[2026-10-31 10:00:00Z])
      stranger = game([other.id], "louisiana", ~U[2026-10-31 11:00:00Z])

      assert {:ok, %{kind: "pace", answer: "too_slow", game_id: game_id, rule_set: "louisiana"}} =
               Feedback.create(answer("pace", "too_slow", named.id), user)

      assert game_id == named.id

      assert {:ok, %{game_id: game_id, rule_set: "finnish"}} =
               Feedback.create(answer("pace", "right", stranger.id), user)

      assert game_id == latest.id
    end

    test "an old-Pidro answer and a skip are saved; other answers are refused", %{user: user} do
      assert {:ok, %{kind: "old_pidro", answer: "better", body: nil}} =
               Feedback.create(answer("old_pidro", "better", nil), user)

      assert {:ok, %{answer: "skipped"}} = Feedback.create(answer("pace", "skipped", nil), user)

      assert {:error, changeset} = Feedback.create(answer("pace", "better", nil), user)
      assert %{answer: ["is invalid"]} = errors_on(changeset)
      assert {:error, changeset} = Feedback.create(answer("rules", "right", nil), user)
      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "ask/2" do
    test "nothing without a game with another person in the last 24 hours",
         %{user: user, other: other} do
      assert Feedback.ask(user, @now) == %{ask: nil}

      game([user.id, other.id], "finnish", ~U[2026-10-31 00:29:59Z])
      game([user.id], "finnish", ~U[2026-11-01 00:10:00Z])
      assert Feedback.ask(user, @now) == %{ask: nil}
    end

    test "pace for the latest game with people, once a UTC day, a skip included",
         %{user: user, other: other} do
      people = game([user.id, other.id], "finnish", ~U[2026-10-31 00:30:00Z])
      game([user.id], "louisiana", ~U[2026-11-01 00:20:00Z])

      assert Feedback.ask(user, @now) == %{ask: "pace", game_id: people.id}

      answered(user, "pace", "right", ~U[2026-10-31 23:59:59Z])
      assert Feedback.ask(user, @now) == %{ask: "pace", game_id: people.id}

      answered(user, "pace", "skipped", ~U[2026-11-01 00:00:00Z])
      assert Feedback.ask(user, @now) == %{ask: nil}
    end

    test "a Classic player is asked about the old Pidro from the third game with people",
         %{user: user, other: other} do
      user =
        user
        |> Ecto.Changeset.change(classic_user_id: 42, classic_claimed_at: DateTime.utc_now())
        |> Repo.update!()

      answered(user, "pace", "too_fast", ~U[2026-11-01 00:01:00Z])

      game([user.id, other.id], "finnish", ~U[2026-09-01 10:00:00Z])
      latest = game([user.id, other.id], "louisiana", ~U[2026-11-01 00:05:00Z])
      game([user.id], "finnish", ~U[2026-10-01 10:00:00Z])
      assert Feedback.ask(user, @now) == %{ask: nil}

      game([user.id, other.id], "finnish", ~U[2026-10-02 10:00:00Z])
      assert Feedback.ask(user, @now) == %{ask: "old_pidro", game_id: latest.id}

      answered(user, "old_pidro", "skipped", ~U[2026-11-01 00:10:00Z])
      assert Feedback.ask(user, @now) == %{ask: nil}
    end

    test "a player without Classic is never asked about the old Pidro",
         %{user: user, other: other} do
      answered(user, "pace", "right", ~U[2026-11-01 00:01:00Z])

      for day <- 1..3,
          do: game([user.id, other.id], "finnish", DateTime.add(@now, -day, :minute))

      assert Feedback.ask(user, @now) == %{ask: nil}
    end
  end

  describe "list/1, set_status/2 and counts/0" do
    test "notes newest first by status", %{user: user} do
      {:ok, first} = Feedback.create(note(%{"body" => "first"}), user)
      {:ok, second} = Feedback.create(note(%{"body" => "second"}), nil)
      {:ok, _answer} = Feedback.create(answer("pace", "right", nil), user)

      assert {:ok, %{status: "done"}} = Feedback.set_status(first.id, "done")
      assert {:error, _} = Feedback.set_status(second.id, "closed")

      assert ids(Feedback.list("all")) == [second.id, first.id]
      assert ids(Feedback.list("open")) == [second.id]
      assert ids(Feedback.list("done")) == [first.id]
      assert hd(Feedback.list("done")).user.id == user.id
    end

    test "answers by rule set, skips left out", %{user: user, other: other} do
      finnish = game([user.id, other.id], "finnish", ~U[2026-10-31 10:00:00Z])
      louisiana = game([user.id, other.id], "louisiana", ~U[2026-10-31 11:00:00Z])

      for {who, kind, value, game} <- [
            {user, "pace", "too_slow", finnish},
            {user, "pace", "too_slow", finnish},
            {other, "pace", "too_fast", louisiana},
            {other, "pace", "skipped", louisiana},
            {user, "old_pidro", "better", finnish},
            {other, "old_pidro", "better", louisiana},
            {other, "old_pidro", "skipped", louisiana}
          ] do
        {:ok, _} = Feedback.create(answer(kind, value, game.id), who)
      end

      assert Feedback.counts() == %{
               pace: %{{"finnish", "too_slow"} => 2, {"louisiana", "too_fast"} => 1},
               old_pidro: %{"better" => 2}
             }
    end
  end

  describe "report/5" do
    setup %{user: user, other: other} do
      game = %{key: "inst-1", instance: "inst-1", room_code: "TALK", rule_set: :finnish}
      %{reporter: user, reported: other, game: game}
    end

    test "saves the reason and the lines the server quotes, and mails the inbox", ctx do
      lines = [%{text: "you play like a child"}, %{item: "coin_ha"}]

      assert {:ok, report} = Feedback.report(ctx.reporter, ctx.reported, "rude", ctx.game, lines)

      assert %Entry{kind: "report", answer: "rude", status: "open", rule_set: "finnish"} = report
      assert {report.user_id, report.reported_user_id} == {ctx.reporter.id, ctx.reported.id}
      assert report.body == "you play like a child\n(coin_ha)"

      assert report.details == %{
               "game" => "inst-1",
               "game_instance_id" => "inst-1",
               "room_code" => "TALK"
             }

      reporter = ctx.reporter.display_name || ctx.reporter.username
      reported = ctx.reported.display_name || ctx.reported.username

      # Sent in the background, so the channel never waits on the mail server.
      assert_receive {:email, email}, 1_000
      assert email.to == [{"", "marcel@pidro.online"}]
      assert email.subject == "Report: #{reporter} about #{reported}"
      assert email.text_body =~ "Reason: rude"
      assert email.text_body =~ "Game: inst-1 (room TALK, finnish)"
      assert email.text_body =~ "you play like a child\n(coin_ha)"
      assert email.text_body =~ "Report ##{report.id}"
    end

    test "one report per reporter, reported player and game", ctx do
      assert {:ok, _} = Feedback.report(ctx.reporter, ctx.reported, "rude", ctx.game, [])

      assert {:error, changeset} =
               Feedback.report(ctx.reporter, ctx.reported, "other", ctx.game, [])

      assert %{user_id: ["already reported"]} = errors_on(changeset)

      assert {:ok, _} =
               Feedback.report(
                 ctx.reporter,
                 ctx.reported,
                 "rude",
                 %{ctx.game | key: "inst-2"},
                 []
               )

      assert {:ok, _} = Feedback.report(ctx.reported, ctx.reporter, "rude", ctx.game, [])
    end

    test "only the three reasons", ctx do
      assert {:error, changeset} =
               Feedback.report(ctx.reporter, ctx.reported, "cheating", ctx.game, [])

      assert %{answer: ["is invalid"]} = errors_on(changeset)
    end

    test "a report counts in no answers, stays out of the notes and lists under reports", ctx do
      {:ok, note} = Feedback.create(note(), ctx.reporter)
      {:ok, report} = Feedback.report(ctx.reporter, ctx.reported, "bothering", ctx.game, [])

      assert Feedback.counts() == %{pace: %{}, old_pidro: %{}}
      assert Enum.map(Feedback.list("all"), & &1.id) == [note.id]
      assert [%{id: id, reported_user: %{id: reported_id}}] = Feedback.list("reports")
      assert {id, reported_id} == {report.id, ctx.reported.id}

      assert {:ok, %{status: "done"}} = Feedback.set_status(report.id, "done")
    end

    test "the app cannot file a report through notes", %{user: user, other: other} do
      assert {:error, changeset} =
               Feedback.create(%{"kind" => "report", "reported_user_id" => other.id}, user)

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end
  end

  defp note(attrs \\ %{}), do: Map.merge(%{"kind" => "note", "body" => "Nice game"}, attrs)

  defp answer(kind, value, game_id),
    do: %{"kind" => kind, "answer" => value, "game_id" => game_id}

  defp game(player_ids, rule_set, completed_at) do
    Repo.insert!(%GameStats{
      room_code: "FDBK",
      rule_set: rule_set,
      completed_at: completed_at,
      player_ids: player_ids
    })
  end

  defp answered(user, kind, answer, at) do
    Repo.insert!(%Entry{
      kind: kind,
      answer: answer,
      user_id: user.id,
      inserted_at: %{at | microsecond: {0, 6}}
    })
  end

  defp ids(entries), do: Enum.map(entries, & &1.id)
end
