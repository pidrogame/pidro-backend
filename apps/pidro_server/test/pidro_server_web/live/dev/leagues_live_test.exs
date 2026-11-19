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
    user_fixture()
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

    report = Report.build()
    assert report.total == 2
    assert [%{members: 1}] = report.rooms
    {:ok, view, html} = live(conn, "/admin/leagues")
    for target <- ["~13%", "~22%", "~29%", "~26%", "~8%"], do: assert(html =~ target)
    assert has_element?(view, "nav a[href='/admin/leagues'][aria-current='page']", "Leagues")
    refute has_element?(view, "#league-close")
    refute function_exported?(Leagues, :dev_close, 1)
    view |> element("button", "Refresh") |> render_click()
    assert has_element?(view, "#league-rooms")
  end

  test "the eleventh game reveals both profiles and the recorded team breakdown", %{conn: conn} do
    a = user_fixture(%{display_name: "Ada Vale"})
    b = user_fixture(%{username: "birch"})
    a |> Ecto.Changeset.change(avatar_face: "a") |> Repo.update!()
    now = DateTime.utc_now()
    {starts, _} = Leagues.week(now)

    north = %{team: "north_south", position: "north"}
    same_team = %{a.id => north, b.id => %{team: "north_south", position: "south"}}
    opposite_teams = %{a.id => %{team: "east_west", position: "east"}, b.id => north}

    save_game([a.id, b.id], DateTime.add(starts, -1), same_team)
    save_game([a.id, b.id], now, %{a.id => north, b.id => north})
    save_game([a.id, b.id], now, nil)
    for _ <- 1..5, do: save_game([a.id, b.id], now, same_team)
    for _ <- 1..4, do: save_game([b.id, a.id], now, opposite_teams)

    {:ok, view, _html} = live(conn, "/admin/leagues")
    assert has_element?(view, "#league-pairs", "No pairs have reached 11 games yet.")
    refute has_element?(view, "#league-pairs table")

    save_game([a.id, b.id], now, same_team)
    view |> element("button", "Refresh") |> render_click()

    row = "#league-pairs tbody tr:only-child"
    assert has_element?(view, "#{row} a[href='/admin/users/#{a.id}']", "Ada Vale")

    assert has_element?(
             view,
             "#{row} a[href='/admin/users/#{a.id}'] img[src$='/images/faces/a.png']"
           )

    assert has_element?(view, "#{row} a[href='/admin/users/#{b.id}']", "birch")
    assert has_element?(view, "#{row} a[href='/admin/users/#{b.id}'] [aria-hidden='true']", "B")

    for {column, header, count} <- [
          {2, "Games", "11"},
          {3, "As teammates", "6"},
          {4, "As opponents", "4"}
        ] do
      assert has_element?(view, "#league-pairs th:nth-child(#{column})", header)
      assert has_element?(view, "#{row} td:nth-child(#{column})", count)
    end

    assert has_element?(view, row, "1 game without team data")
    assert has_element?(view, row, "Level 1")
  end

  test "historical pairs without a current player profile still count", %{conn: conn} do
    player = user_fixture()
    missing = Ecto.UUID.generate()
    for _ <- 1..12, do: save_game([player.id, missing], DateTime.utc_now(), nil)
    {:ok, view, _html} = live(conn, "/admin/leagues")
    assert has_element?(view, "#league-pairs tbody tr", "Unknown player")
    assert has_element?(view, "#league-pairs tbody tr", "12 games without team data")
    assert has_element?(view, "#league-pairs tbody td:nth-child(3)", "—")
    refute has_element?(view, "#league-pairs a[href='/admin/users/#{missing}']")
  end

  test "old bookmarks redirect and both routes require an authenticated admin with a changed password",
       %{conn: conn} do
    assert redirected_to(get(conn, "/dev/leagues")) == "/admin/leagues"
    temporary = PidroServer.AdminsFixtures.admin_fixture(%{force_password_change: true})

    for path <- ["/dev/leagues", "/admin/leagues"] do
      assert redirected_to(get(build_conn(), path)) == "/admin/login"

      assert redirected_to(build_conn() |> log_in_admin(temporary) |> get(path)) ==
               "/admin/admins"
    end
  end

  defp save_game(players, at, results) do
    {:ok, _} =
      Stats.save_game_result(%{
        room_code: "PAIR",
        completed_at: at,
        player_ids: players,
        player_results: results
      })
  end
end
