defmodule PidroServerWeb.Dev.LeaguesLiveTest do
  use PidroServerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import PidroServer.AccountsFixtures
  alias PidroServer.{Leagues, Repo, Stats}
  alias PidroServer.Leagues.{Membership, Report, Room}
  setup :register_and_log_in_admin

  test "admin report shows room counts, distribution targets and no production close action", %{
    conn: conn
  } do
    a = user_fixture()
    b = user_fixture()
    {starts, closes} = Leagues.week(DateTime.utc_now())
    now = DateTime.utc_now()
    room = Repo.insert!(%Room{league: "deuce", starts_at: starts, closes_at: closes})

    Repo.insert!(%Membership{
      room_id: room.id,
      user_id: a.id,
      closes_at: closes,
      points: 123,
      points_at: now,
      placed_at: now
    })

    for i <- 1..11 do
      Stats.save_game_result(%{
        room_code: "pair#{i}",
        completed_at: now,
        player_ids: [a.id, b.id]
      })
    end

    report = Report.build()
    assert report.total == 2
    assert [%{games: 11}] = report.pairs
    assert [%{members: 1}] = report.rooms
    {:ok, view, html} = live(conn, "/dev/leagues")
    for target <- ["~13%", "~22%", "~29%", "~26%", "~8%"], do: assert(html =~ target)
    refute has_element?(view, "#league-close")
    refute function_exported?(Leagues, :dev_close, 1)
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#league-rooms")
    assert {:error, {:redirect, _}} = live(build_conn(), "/dev/leagues")
  end
end
