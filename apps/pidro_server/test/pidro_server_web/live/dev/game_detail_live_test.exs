defmodule PidroServerWeb.Dev.GameDetailLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.Bots.BotBrain
  alias PidroServer.Games.Bots.Strategies.RulebookStrategy
  alias PidroServer.Games.{GameAdapter, RoomManager}

  setup :register_and_log_in_admin

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    :ok
  end

  test "renders recent users in the take-a-seat controls using username fallback", %{conn: conn} do
    host = AccountsFixtures.user_fixture(%{username: "debug_host"})
    recent_user = AccountsFixtures.user_fixture(%{username: "debug_recent"})
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Debug Table"})

    {:ok, _view, html} = live(conn, ~p"/admin/games/#{room.code}?tab=controls")

    assert html =~ "Take a Seat"
    assert html =~ recent_user.username
  end

  test "renders an ownerless room", %{conn: conn} do
    host = AccountsFixtures.user_fixture(%{username: "departed_host"})
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Ownerless Table"})
    set_room_owner(room.code, nil)

    {:ok, _view, html} = live(conn, ~p"/admin/games/#{room.code}?tab=inspect")

    assert html =~ "No owner"
  end

  test "watch resolves seated users outside the recent list and cannot reassign seats", %{
    conn: conn
  } do
    host = AccountsFixtures.user_fixture(%{username: "older_seated_user"})

    host
    |> Ecto.Changeset.change(inserted_at: ~U[2020-01-01 00:00:00.000000Z])
    |> PidroServer.Repo.update!()

    {:ok, room} = RoomManager.create_room(host.id, %{name: "Observation"})
    for _ <- 1..21, do: AccountsFixtures.user_fixture()
    refute Enum.any?(PidroServer.Accounts.Auth.list_recent_users(20), &(&1.id == host.id))

    {:ok, view, html} = live(conn, ~p"/admin/games/#{room.code}")
    assert has_element?(view, "#watch-table a[href='/admin/users/#{host.id}']", host.username)
    refute html =~ "Take a Seat"
    refute has_element?(view, "[phx-click=execute_action]")
    refute has_element?(view, "#copy-game-state")

    assert render_submit(view, "assign_seat", %{position: "north", user_id: "empty"}) =~
             "Enter Controls"

    assert {:ok, unchanged} = RoomManager.get_room(room.code)
    assert unchanged.positions == room.positions
  end

  test "snapshot renderer accepts a fourth opaque bot profile and does not invent portrait URLs" do
    alias PidroServerWeb.CardComponents

    profile = %{
      id: Ecto.UUID.generate(),
      name: "Fourth Crew",
      avatar_url: "/api/v1/bots/fourth/avatar/hash"
    }

    seat = %{status: :permanent_bot, bot_persona: profile.id, bot_profile: profile}
    html = render_component(&CardComponents.watch_table/1, seats: %{north: seat})
    assert html =~ "Fourth Crew"
    assert html =~ profile.avatar_url
    assert html =~ "href=\"/admin/bots\""
    refute html =~ "phx-click"

    fallback =
      render_component(&CardComponents.watch_table/1,
        seats: %{north: Map.delete(seat, :bot_profile)}
      )

    refute fallback =~ profile.id
    refute fallback =~ "/images/bots/"
  end

  test "bot manager outage preserves observation and recovers on the scheduled refresh", %{
    conn: conn
  } do
    alias PidroServer.Games.Bots.BotManager
    host = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Status outage"})
    {:ok, _} = BotManager.start_bot(room.code, :east, :random, 1_000)
    :ok = BotManager.pause_bot(room.code, :east)
    {:ok, view, _} = live(conn, ~p"/admin/games/#{room.code}")
    assert has_element?(view, "#watch-status", "Bots paused")
    manager = Process.whereis(BotManager)
    Process.unregister(BotManager)

    try do
      send(view.pid, :refresh_bot_status)
      assert has_element?(view, "#watch-status", "Bots paused")
      {:ok, mounted_during_outage, _} = live(conn, ~p"/admin/games/#{room.code}")
      assert has_element?(mounted_during_outage, "#watch-seat-north", host.username)
      assert Process.alive?(view.pid)
    after
      Process.register(manager, BotManager)
    end

    :ok = BotManager.resume_bot(room.code, :east)
    Process.sleep(2_100)
    refute has_element?(view, "#watch-status", "Bots paused")
    assert has_element?(view, "#watch-seat-north", host.username)
  end

  describe "bot reasoning" do
    setup do
      original = Application.get_env(:pidro_server, PidroServer.Games.Lifecycle, [])

      Application.put_env(
        :pidro_server,
        PidroServer.Games.Lifecycle,
        Keyword.merge(original, turn_timer_bid_ms: 60_000, turn_timer_play_ms: 60_000)
      )

      on_exit(fn ->
        Application.put_env(:pidro_server, PidroServer.Games.Lifecycle, original)
      end)

      [host | others] = for _ <- 1..4, do: AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Reasons"})
      for user <- others, do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
      PidroServer.RoomFixtures.ready_room(room.code)
      {:ok, game} = GameAdapter.get_state(room.code)

      if game.phase == :dealer_selection,
        do: {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)

      wait_for_bidding(room.code)
      %{room: room}
    end

    defp wait_for_bidding(room_code, attempts \\ 400) do
      case GameAdapter.get_state(room_code) do
        {:ok, %{phase: :bidding, current_turn: turn}} when turn != nil ->
          :ok

        _ when attempts > 0 ->
          Process.sleep(5)
          wait_for_bidding(room_code, attempts - 1)

        other ->
          flunk("bidding never started: #{inspect(other, limit: 3)}")
      end
    end

    defp bot_move(room_code) do
      {:ok, game} = GameAdapter.get_state(room_code)

      :ok =
        BotBrain.execute_move(
          %{room_code: room_code, position: game.current_turn, strategy: RulebookStrategy},
          "Test"
        )

      game.current_turn
    end

    test "a bot move publishes one reason on its own topic and none on the game topic", %{
      room: room
    } do
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, BotBrain.reasoning_topic(room.code))
      {:ok, before} = GameAdapter.get_state(room.code)

      position = bot_move(room.code)

      assert_receive {:bot_reasoning, code, %{position: ^position, reason: reason} = payload}
      assert code == room.code
      assert payload.event_index == length(before.events)
      assert reason =~ ~r/^[A-Z][^.]*\.$/
      refute_receive {:bot_reasoning, _, _}, 100
    end

    test "a failed action publishes nothing", %{room: room} do
      Phoenix.PubSub.subscribe(PidroServer.PubSub, BotBrain.reasoning_topic(room.code))
      {:ok, game} = GameAdapter.get_state(room.code)

      ExUnit.CaptureLog.capture_log(fn ->
        BotBrain.execute_move(
          %{room_code: room.code, position: game.current_turn, strategy: RulebookStrategy},
          "Test",
          fn _code, _position, _action, _turn -> {:error, :rejected} end
        )
      end)

      refute_receive {:bot_reasoning, _, _}, 100
    end

    test "shows newest actions and their reasons first, only while the toggle is on",
         %{conn: conn, room: room} do
      {:ok, view, _html} = live(conn, ~p"/admin/games/#{room.code}?tab=activity")

      first = bot_move(room.code)
      second = bot_move(room.code)
      html = render(view)

      first_reason = :binary.match(html, "#{position_name(first)} (Bot) chose")
      second_reason = :binary.match(html, "#{position_name(second)} (Bot) chose")
      assert first_reason != :nomatch and second_reason != :nomatch
      assert first_action(html, second) < second_reason
      assert second_reason < first_action(html, first)
      assert first_action(html, first) < first_reason

      html = view |> element("input[phx-click=toggle_bot_reasoning]") |> render_click()
      refute html =~ "(Bot) chose"

      html = view |> element("input[phx-click=toggle_bot_reasoning]") |> render_click()
      assert html =~ "(Bot) chose"
    end

    test "undo removes the reason for the undone move and keeps earlier ones",
         %{conn: conn, room: room} do
      {:ok, view, _html} = live(conn, ~p"/admin/games/#{room.code}?tab=activity")

      first = bot_move(room.code)
      second = bot_move(room.code)
      assert render(view) =~ "#{position_name(second)} (Bot) chose"

      view |> element("a[href$='tab=controls']") |> render_click()
      view |> element("button[phx-click=undo_last_action]") |> render_click()
      html = view |> element("a[href$='tab=activity']") |> render_click()

      assert html =~ "#{position_name(first)} (Bot) chose"
      refute html =~ "#{position_name(second)} (Bot) chose"
    end

    test "a page opened mid-game renders without earlier reasons", %{conn: conn, room: room} do
      bot_move(room.code)
      {:ok, view, html} = live(conn, ~p"/admin/games/#{room.code}?tab=activity")

      refute html =~ "(Bot) chose"
      assert Process.alive?(view.pid)

      bot_move(room.code)
      assert render(view) =~ "(Bot) chose"
    end

    test "perspective and replay never mutate the live game, and broadcasts do not overwrite replay",
         %{conn: conn, room: room} do
      {:ok, before} = GameAdapter.get_state(room.code)
      {:ok, view, _} = live(conn, ~p"/admin/games/#{room.code}")
      view |> element("button[phx-value-position=south]") |> render_click()
      assert has_element?(view, "#watch-seat-north img[alt='Face-down card']")
      refute has_element?(view, "#watch-seat-south img[alt='Face-down card']")
      assert {:ok, ^before} = GameAdapter.get_state(room.code)
      assert render_click(view, "undo_last_action") =~ "Enter Controls"
      assert {:ok, ^before} = GameAdapter.get_state(room.code)
      view |> element("[phx-click=toggle_replay_mode]") |> render_click()
      frozen = view |> element("#watch-table") |> render()
      bot_move(room.code)
      assert view |> element("#watch-table") |> render() == frozen
      view |> element("a[href$='tab=controls']") |> render_click()
      {:ok, live_state} = GameAdapter.get_state(room.code)
      assert render_click(view, "undo_last_action") =~ "exit replay"
      assert {:ok, ^live_state} = GameAdapter.get_state(room.code)
      view |> element("[phx-click=toggle_replay_mode]") |> render_click()
      view |> element("a[href$='tab=board']") |> render_click()
      refute view |> element("#watch-table") |> render() == frozen
      view |> element("[phx-click=toggle_replay_mode]") |> render_click()
      count = length(live_state.events)
      assert render(view) =~ "Event #{count} of #{count}"
      assert has_element?(view, "input[type=range][max='#{count - 1}']")
    end

    test "all replay controls retain their captured source across a same-room restart", %{
      conn: conn,
      room: room
    } do
      bot_move(room.code)
      {:ok, original} = GameAdapter.get_state(room.code)
      count = length(original.events)
      {:ok, view, _} = live(conn, ~p"/admin/games/#{room.code}")
      render_click(view, "toggle_replay_mode")
      final_table = view |> element("#watch-table") |> render()
      render_change(view, "replay_jump_to", %{index: "1"})
      dealt_table = view |> element("#watch-table") |> render()

      bot_move(room.code)

      PidroServer.Repo.get!(PidroServer.Accounts.User, room.positions.north)
      |> Ecto.Changeset.change(username: "renamed_after_capture")
      |> PidroServer.Repo.update!()

      Phoenix.PubSub.broadcast(PidroServer.PubSub, "room:#{room.code}", {:room_updated, room})
      view |> element("a[href$='tab=activity']") |> render_click()
      refute render(view) =~ "(Bot) chose"
      render_click(view, "refresh_events")
      refute render(view) =~ "renamed_after_capture"
      view |> element("a[href$='tab=board']") |> render_click()
      assert view |> element("#watch-table") |> render() == dealt_table

      :ok = PidroServer.Games.GameSupervisor.stop_game(room.code)
      {:ok, _} = PidroServer.Games.GameSupervisor.start_game(room.code)
      {:ok, replacement} = GameAdapter.get_state(room.code)
      assert replacement.events == []

      render_click(view, "replay_step_backward")
      assert render(view) =~ "Event 1 of #{count}"
      render_click(view, "replay_step_forward")
      assert view |> element("#watch-table") |> render() == dealt_table
      assert render(view) =~ "Cards dealt to all players"
      render_change(view, "replay_jump_to_phase", %{phase: "bidding"})
      assert view |> element("#watch-table") |> render() == dealt_table
      render_change(view, "replay_jump_to", %{index: to_string(count - 1)})
      assert view |> element("#watch-table") |> render() == final_table

      assert render_change(view, "replay_jump_to", %{index: to_string(count)}) =~
               "Invalid event index"

      render_click(view, "replay_toggle_play")
      assert render(view) =~ "Event #{count} of #{count}"
      assert view |> element("#watch-table") |> render() == final_table
      assert render_click(view, "execute_action", %{action: "\"select_dealer\""}) =~ "exit replay"
      assert {:ok, ^replacement} = GameAdapter.get_state(room.code)
      render_click(view, "toggle_replay_mode")
      assert has_element?(view, "#watch-table .watch-phase", "dealer selection")
      assert has_element?(view, "#watch-seat-north", "renamed_after_capture")
      refute has_element?(view, "[phx-click=replay_step_backward]")
    end

    # The first bid or pass line for the seat in the event log.
    defp first_action(html, position) do
      name = position_name(position)

      [" passed", " bid "]
      |> Enum.map(&:binary.match(html, name <> &1))
      |> Enum.reject(&(&1 == :nomatch))
      |> Enum.min()
    end

    defp position_name(position),
      do: position |> Atom.to_string() |> String.capitalize()
  end

  defp set_room_owner(room_code, host_id) do
    :sys.replace_state(RoomManager, fn state ->
      update_in(state.rooms[room_code], &%{&1 | host_id: host_id})
    end)
  end
end
