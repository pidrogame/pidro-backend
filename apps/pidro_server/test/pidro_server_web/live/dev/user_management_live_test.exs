defmodule PidroServerWeb.Dev.UserManagementLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias PidroServer.Accounts.{Auth, ClassicNameReservations, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Profiles
  alias PidroServer.Stats

  setup :register_and_log_in_admin

  @tag :flaky_connections
  test "player connection summary counts only the last seven days", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {kind, days, metadata} <- [
          {"drop", 1, nil},
          {"drop", 2, nil},
          {"timeout", 3, nil},
          {"away_play", 3, %{"actor" => "timer", "action" => %{"type" => "pass"}}},
          {"away_play", 3, %{"actor" => "timer", "action" => %{"type" => "pass"}}},
          {"away_play", 3, %{"actor" => "bot", "action" => %{"type" => "pass"}}},
          {"drop", 8, nil},
          {"timeout", 8, nil},
          {"away_play", 8, %{"actor" => "bot", "action" => %{"type" => "pass"}}}
        ] do
      PidroServer.Repo.insert!(%PidroServer.Stats.SeatEvent{
        user_id: user.id,
        room_code: "L5V3",
        kind: kind,
        reason: "heartbeat_timeout",
        network: "cellular",
        platform: "android",
        app_version: "3.2.3",
        metadata: metadata,
        inserted_at: DateTime.add(now, -days, :day) |> DateTime.to_naive()
      })
    end

    Stats.record_connection_game(%{
      user_id: user.id,
      room_id: Ecto.UUID.generate(),
      room_code: "L5V3",
      game_instance_id: Ecto.UUID.generate(),
      duration_seconds: 3600,
      disconnected_seconds: 24,
      checks_sent: 240,
      unanswered_checks: 4,
      drops: 2,
      rtt_histogram: %{"420" => 18, "2000" => 2},
      network_ms: %{"cellular" => 3_600_000},
      network: "cellular",
      platform: "android",
      app_version: "3.2.3"
    })

    PidroServer.DataCase.await_tasks()

    {:ok, view, _} = live(conn, ~p"/admin/users/#{user.id}")

    assert has_element?(
             view,
             "#connection-quality",
             "2 drops, 4 plays made for them (timer 3, bot 1) in the last 7 days"
           )

    assert has_element?(view, "#connection-strength", "poor: typically 420 ms")
    assert has_element?(view, "#connection-strength", "mostly cellular")
    assert has_element?(view, "#connection-strip", "420 ms")
    assert has_element?(view, "#connection-strip", "2 drops")
    assert has_element?(view, "#connection-timeline", "heartbeat_timeout · cellular")
    assert has_element?(view, "#connection-timeline", "android 3.2.3")
    assert has_element?(view, "#connection-timeline", "UTC")
  end

  @tag :flaky_connections
  test "player connection timeline says who played for an away player", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    for {kind, metadata} <- [
          {"bot_took_seat", %{"trigger" => "missed_turns"}},
          {"bot_took_seat", %{"trigger" => "drop"}},
          {"bot_took_seat", nil},
          {"seat_taken_back", nil},
          {"away_play",
           %{
             "actor" => "bot",
             "action" => %{"type" => "play_card", "card" => %{"rank" => 10, "suit" => "spades"}}
           }},
          {"away_play",
           %{
             "actor" => "timer",
             "action" => %{"type" => "play_card", "card" => %{"rank" => 5, "suit" => "clubs"}}
           }},
          {"away_play", %{"actor" => "timer", "action" => %{"type" => "bid", "amount" => 8}}},
          {"away_play", %{"actor" => "bot", "action" => %{"type" => "pass"}}},
          {"away_play",
           %{"actor" => "bot", "action" => %{"type" => "declare_trump", "suit" => "hearts"}}},
          {"away_play", %{"actor" => "robot", "action" => %{"type" => "shuffle"}}},
          {"away_play", nil},
          {"teleport", %{"to" => "the moon"}}
        ] do
      PidroServer.Repo.insert!(%PidroServer.Stats.SeatEvent{
        user_id: user.id,
        room_code: "3QKP",
        kind: kind,
        metadata: metadata
      })
    end

    # The same second, and ids that would list the drop first.
    for {kind, id} <- [{"drop", "ffffffff"}, {"return", "00000000"}] do
      PidroServer.Repo.insert!(%PidroServer.Stats.SeatEvent{
        id: "#{id}-0000-4000-8000-000000000000",
        user_id: user.id,
        room_code: "3QKP",
        kind: kind,
        reason: "backgrounded",
        inserted_at: ~N[2026-11-06 22:04:15]
      })
    end

    {:ok, view, html} = live(conn, ~p"/admin/users/#{user.id}")
    [_, newest_first] = String.split(html, "2026-11-06T22:04:15", parts: 2)
    assert :binary.match(newest_first, "Return") < :binary.match(newest_first, "Drop")

    for row <- [
          "Bot took the seat (three missed turns)",
          "Bot took the seat (connection lost)",
          "Took the seat back",
          "Bot played 10♠ for them",
          "Timer played 5♣ for them",
          "Timer bid 8 for them",
          "Bot passed for them",
          "Bot chose ♥ as trump for them",
          "Played for them",
          "Teleport"
        ] do
      assert has_element?(view, "#connection-timeline li", row)
    end
  end

  test "lists players with search filters and summary stats", %{conn: conn} do
    alpha =
      AccountsFixtures.user_fixture(%{username: "admin_alpha", display_name: "Alpha Player"})

    beta = AccountsFixtures.user_fixture(%{username: "admin_beta", guest: true})

    save_game(alpha, "ALFA1", "win")

    {:ok, view, html} = live(conn, ~p"/admin/users")

    assert html =~ "Pidro Ops"
    assert html =~ "Players"
    assert has_element?(view, "a[href='/admin/users/#{alpha.id}']", "Alpha Player")
    assert html =~ "@admin_alpha"
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
    user =
      AccountsFixtures.user_fixture(%{username: "detail_player", display_name: "Old Public Name"})

    save_game(user, "DETL1", "win")

    {:ok, view, html} = live(conn, ~p"/admin/users/#{user.id}")

    assert has_element?(view, "h1", "Old Public Name")
    assert html =~ "@detail_player"
    assert html =~ "Completed games"
    assert html =~ "DETL1"
    assert html =~ "WIN"

    render_submit(view, "save", %{
      "user" => %{
        "username" => "detail_renamed",
        "display_name" => "  New   Public Name  ",
        "email" => "renamed@example.com",
        "guest" => "false"
      }
    })

    updated = Auth.get_user(user.id)
    assert updated.username == "detail_renamed"
    assert updated.email == "renamed@example.com"
    refute updated.guest
    assert User.public_name(updated) == "New Public Name"
    assert has_element?(view, "h1", "New Public Name")
    assert page_title(view) =~ "New Public Name"
    assert render(view) =~ "@detail_renamed"

    view |> form("#player-form", user: %{display_name: ""}) |> render_submit()
    cleared = Auth.get_user(user.id)
    assert is_nil(cleared.display_name)
    assert User.public_name(cleared) == "detail_renamed"
    assert has_element?(view, "h1", "detail_renamed")
  end

  test "admin name edits enforce the same policy and reservation errors as registration", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture(%{display_name: "Original Name"})
    taken = AccountsFixtures.user_fixture()
    {:ok, _} = ClassicNameReservations.import([%{id: 601, username: "Classic Hero"}])
    {:ok, view, _} = live(conn, ~p"/admin/users/#{user.id}")

    for {field, name} <- [
          {:display_name, " classic   HERO "},
          {:display_name, "Fuckface"},
          {:display_name, "line\nbreak"},
          {:display_name, "x"},
          {:display_name, String.duplicate("x", 21)},
          {:username, taken.username}
        ] do
      attrs = %{field => name}

      {:error, player_error} =
        Auth.register_user(
          Map.merge(
            %{
              username: AccountsFixtures.unique_username(),
              email: AccountsFixtures.unique_user_email(),
              password: AccountsFixtures.valid_user_password()
            },
            attrs
          )
        )

      assert {:error, admin_error} = Auth.update_user(user, attrs)
      assert admin_error.errors[field] == player_error.errors[field]

      assert render_submit(view, "save", %{"user" => %{Atom.to_string(field) => name}}) =~
               "Fix the highlighted fields"

      assert User.public_name(Auth.get_user(user.id)) == "Original Name"
    end

    assert render_submit(view, "save", %{"user" => %{"display_name" => "Classic Hero"}}) =~
             "This name belongs to a Classic player. Claim your Classic profile or choose another name."

    assert render_submit(view, "save", %{"user" => %{"username" => taken.username}}) =~
             "has already been taken"
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
