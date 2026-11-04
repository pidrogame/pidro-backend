defmodule PidroServerWeb.Dev.DashboardLiveTest do
  use PidroServerWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias PidroServer.Games.{PresenceAggregator, RoomManager}

  setup :register_and_log_in_admin

  setup do
    PresenceAggregator.reset_for_test()
    RoomManager.reset_for_test()

    on_exit(fn ->
      PresenceAggregator.reset_for_test()
      PidroServer.RoomManagerCase.cleanup()
    end)

    :ok
  end

  test "shows real arrivals and updates a deduplicated human roster", %{conn: conn} do
    user = PidroServer.AccountsFixtures.user_fixture()
    PidroServer.AccountsFixtures.guest_fixture()
    now = DateTime.utc_now()
    PidroServer.AccountsFixtures.guest_fixture(%{inserted_at: DateTime.add(now, -86_400)})
    PidroServer.AccountsFixtures.guest_fixture(%{inserted_at: DateTime.add(now, 86_400)})
    PresenceAggregator.track(user.id, :lobby)
    parent = self()

    pid =
      spawn(fn ->
        PresenceAggregator.track(user.id, :playing)
        PresenceAggregator.get_count()
        send(parent, :tracked)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :tracked
    on_exit(fn -> Process.exit(pid, :kill) end)
    {:ok, view, _html} = live(conn, ~p"/admin/dashboard")
    assert has_element?(view, "#arrivals-title", "Today's arrivals")
    assert has_element?(view, "#online-total", "1")
    assert view |> element("#new-total") |> render() =~ ">2</dd>"
    assert has_element?(view, "#online-#{user.id}", "Playing")
    PresenceAggregator.reset_for_test()
    send(view.pid, :sample)
    assert has_element?(view, "#online-total", "0")
    refute has_element?(view, "#online-#{user.id}")
  end

  test "unattended rooms are visible without inflating attended tables", %{conn: conn} do
    {:ok, room} = RoomManager.create_room("test-host", %{name: "Campaign table"})
    RoomManager.dev_set_position(room.code, :north, nil)
    {:ok, view, _} = live(conn, ~p"/admin/dashboard")
    assert has_element?(view, "a[href='/admin/games/#{room.code}']", "Campaign table")
    assert render(view) =~ "0 attended"
    assert render(view) =~ "Unattended"
  end

  test "overview requires an admin session" do
    conn = get(build_conn(), ~p"/admin/dashboard")
    assert redirected_to(conn) == ~p"/admin/login"
  end

  test "admin entry redirects authenticated admins to overview", %{conn: conn} do
    assert get(conn, ~p"/admin") |> redirected_to() == ~p"/admin/dashboard"
  end
end
