defmodule PidroServerWeb.Dev.FeedbackLiveTest do
  use PidroServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PidroServer.AccountsFixtures
  alias PidroServer.Feedback
  alias PidroServer.Repo
  alias PidroServer.Stats.GameStats

  setup :register_and_log_in_admin

  test "shows the answers by rule set and works through the notes", %{conn: conn} do
    player = AccountsFixtures.user_fixture(%{display_name: "Aino"})

    game =
      Repo.insert!(%GameStats{
        room_code: "FDBK",
        rule_set: "finnish",
        completed_at: ~U[2026-10-31 10:00:00Z],
        player_ids: [player.id]
      })

    {:ok, _} = Feedback.create(%{"kind" => "pace", "answer" => "too_slow"}, player)
    {:ok, _} = Feedback.create(%{"kind" => "pace", "answer" => "skipped"}, player)
    {:ok, _} = Feedback.create(%{"kind" => "old_pidro", "answer" => "better"}, player)

    {:ok, note} =
      Feedback.create(
        %{"kind" => "note", "body" => "Love the bots", "details" => %{"app_version" => "1.4.0"}},
        player
      )

    {:ok, guest_note} = Feedback.create(%{"kind" => "note", "body" => "Who am I?"}, nil)

    {:ok, view, _html} = live(conn, ~p"/admin/feedback")

    assert cells(view, "#pace-finnish") == ["Finnish", "1", "0", "0"]
    assert cells(view, "#pace-louisiana") == ["Louisiana", "0", "0", "0"]
    assert cells(view, "#old-pidro") == ["Classic players", "0", "0", "1"]

    assert view |> element("#note-#{note.id} a[href='/admin/users/#{player.id}']") |> render() =~
             "Aino"

    assert has_element?(view, "#note-#{note.id} a[href='/admin/history/summaries/#{game.id}']")
    assert render(element(view, "#note-#{note.id}")) =~ player.email
    assert render(element(view, "#note-#{guest_note.id}")) =~ "Guest"
    assert render(element(view, "#note-#{guest_note.id}")) =~ "No reply address"

    view |> element("#note-#{note.id} button", "Done") |> render_click()
    refute has_element?(view, "#note-#{note.id}")

    {:ok, view, _html} = live(conn, ~p"/admin/feedback?status=done")
    assert has_element?(view, "#note-#{note.id}")
    refute has_element?(view, "#note-#{guest_note.id}")

    view |> element("#note-#{note.id} button", "Reopen") |> render_click()
    refute has_element?(view, "#note-#{note.id}")

    {:ok, answer} = Feedback.create(%{"kind" => "pace", "answer" => "right"}, player)

    for {id, status} <- [{"abc", "done"}, {"#{answer.id}", "done"}, {"#{note.id}", "closed"}] do
      assert render_click(view, "set_status", %{"id" => id, "status" => status}) =~
               "That note could not be changed."
    end

    assert Repo.get!(Feedback.Entry, note.id).status == "open"
  end

  defp cells(view, selector) do
    view
    |> element(selector)
    |> render()
    |> then(&LazyHTML.from_fragment("<table>#{&1}</table>"))
    |> LazyHTML.query("td")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
