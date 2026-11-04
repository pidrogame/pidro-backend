defmodule PidroServerWeb.Dev.UserManagementLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias PidroServer.Accounts.Auth
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Profiles
  alias PidroServer.Stats

  setup :register_and_log_in_admin

  test "lists players with search filters and summary stats", %{conn: conn} do
    alpha = AccountsFixtures.user_fixture(%{username: "admin_alpha"})
    beta = AccountsFixtures.user_fixture(%{username: "admin_beta", guest: true})

    save_game(alpha, "ALFA1", "win")

    {:ok, view, html} = live(conn, ~p"/admin/users")

    assert html =~ "Pidro Ops"
    assert html =~ "Players"
    assert html =~ "admin_alpha"
    assert html =~ "admin_beta"
    assert html =~ "1 wins"

    html =
      render_change(view, "filter_users", %{
        "filters" => %{"search" => "admin_alpha", "guest" => "all", "sort" => "recent"}
      })

    assert html =~ "admin_alpha"
    refute html =~ "admin_beta"

    html =
      render_change(view, "filter_users", %{
        "filters" => %{"search" => "", "guest" => "guest", "sort" => "recent"}
      })

    assert html =~ "admin_beta"
    refute html =~ "admin_alpha"

    render_click(view, "request_delete", %{"id" => beta.id})
    assert render(view) =~ "Delete admin_beta?"

    render_click(view, "confirm_delete")
    refute Auth.get_user(beta.id)
  end

  test "shows player detail, history, and allows profile edits", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{username: "detail_player"})
    save_game(user, "DETL1", "win")

    {:ok, view, html} = live(conn, ~p"/admin/users/#{user.id}")

    assert html =~ "detail_player"
    assert html =~ "Completed games"
    assert html =~ "DETL1"
    assert html =~ "WIN"

    render_submit(view, "save", %{
      "user" => %{
        "username" => "detail_renamed",
        "email" => "renamed@example.com",
        "guest" => "false"
      }
    })

    updated = Auth.get_user(user.id)
    assert updated.username == "detail_renamed"
    assert updated.email == "renamed@example.com"
    refute updated.guest

    assert render(view) =~ "detail_renamed"
  end

  test "deletes a player from the detail screen", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{username: "delete_detail_player"})

    {:ok, view, _html} = live(conn, ~p"/admin/users/#{user.id}")

    render_click(view, "request_delete")
    assert render(view) =~ "Delete delete_detail_player?"

    render_click(view, "confirm_delete")
    assert_redirect(view, ~p"/admin/users")
    refute Auth.get_user(user.id)
  end

  test "detail page shows progression for a player with a populated profile", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{username: "veteran_player"})

    # Real import path: carries veteran XP/level + heritage flags.
    {:ok, _profile} =
      Profiles.import_legacy_progression(user.id, %{
        xp: 5000,
        badges: ["Champion"],
        founding_member: true,
        premium: true
      })

    # Earn at least one achievement through the real award path.
    :awarded = Profiles.award_achievement(user.id, :player)

    {:ok, _view, html} = live(conn, ~p"/admin/users/#{user.id}")

    assert html =~ "Progression"
    # Veteran level + title (level_for_xp(5000) is well above level 1).
    assert html =~ "Lvl "
    assert html =~ "5000 XP total"
    # A fresh import is Provisional (skill left at default, count 0).
    assert html =~ "Provisional"
    # Internal estimator line is surfaced for admins.
    assert html =~ "Internal"
    # Mastery: the awarded achievement name.
    assert html =~ "Player"
    # Heritage: migrated player flags.
    assert html =~ "Played Pidro 1"
  end

  test "detail page renders cleanly for a never-played user", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{username: "rookie_player"})

    {:ok, _view, html} = live(conn, ~p"/admin/users/#{user.id}")

    assert html =~ "Progression"
    assert html =~ "Provisional"
    assert html =~ "No achievements earned yet"
    assert html =~ "Not enough data yet"
  end

  test "detail page names a live room from its config and falls back to the room code", %{
    conn: conn
  } do
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    named_host = AccountsFixtures.user_fixture(%{username: "named_room_host"})
    unnamed_host = AccountsFixtures.user_fixture(%{username: "unnamed_room_host"})

    {:ok, _named} = RoomManager.create_room(named_host.id, %{name: "Friday Table"})
    {:ok, unnamed} = RoomManager.create_room(unnamed_host.id)

    {:ok, _view, named_html} = live(conn, ~p"/admin/users/#{named_host.id}")
    assert named_html =~ "Friday Table"

    {:ok, _view, unnamed_html} = live(conn, ~p"/admin/users/#{unnamed_host.id}")
    assert unnamed_html =~ "Game #{unnamed.code}"
  end

  test "list shows level and skill tier cells", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{username: "list_level_player"})

    {:ok, _profile} = Profiles.import_legacy_progression(user.id, %{xp: 5000})

    {:ok, _view, html} = live(conn, ~p"/admin/users")

    assert html =~ "Level"
    assert html =~ "Skill tier"
    assert html =~ "Lvl "
    assert html =~ "Provisional"
  end

  test "Legends show their stars in the list and on the detail page", %{conn: conn} do
    legend = AccountsFixtures.user_fixture(%{username: "list_legend"})
    capped = AccountsFixtures.user_fixture(%{username: "list_capped"})
    regular = AccountsFixtures.user_fixture(%{username: "list_regular"})

    for {user, xp} <- [{legend, 2_800_000}, {capped, 800_000}, {regular, 11_520}] do
      {:ok, _profile} = Profiles.get_or_create_profile(user.id)

      PidroServer.Repo.update_all(
        from(p in PidroServer.Profiles.PlayerProfile, where: p.user_id == ^user.id),
        set: [veteran_xp: xp]
      )
    end

    {:ok, _view, html} = live(conn, ~p"/admin/users")

    assert html =~ "Legend ★4"
    assert html =~ "Lvl 100 · Legend"
    assert html =~ "Lvl 12"

    for {user, label} <- [
          {legend, "Legend ★4"},
          {capped, "Lvl 100 · Legend"},
          {regular, "Lvl 12"}
        ] do
      {:ok, _view, html} = live(conn, ~p"/admin/users/#{user.id}")
      assert html =~ label
    end
  end

  defp save_game(user, room_code, result) do
    winner = if result == "win", do: "north_south", else: "east_west"

    {:ok, _game} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: %{"north_south" => 62, "east_west" => 41},
        duration_seconds: 900,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        player_ids: [user.id],
        player_results: %{
          user.id => %{
            "participation" => "played",
            "result" => result,
            "team" => "north_south",
            "position" => "north"
          }
        }
      })
  end
end
