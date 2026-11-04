defmodule PidroServerWeb.Dev.GameListLiveTest do
  use PidroServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PidroServer.Games.{AdminGameSummary, GameAdapter, GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Games.Room.Config
  alias PidroServer.RoomFixtures

  setup :register_and_log_in_admin

  setup do
    original = Application.get_env(:pidro_server, Lifecycle, [])

    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    on_exit(fn ->
      Application.put_env(:pidro_server, Lifecycle, original)
    end)

    :ok
  end

  test "developer controls stay open across live samples", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/admin/games")
    refute has_element?(view, "#developer-controls[open]")
    view |> element("#developer-controls summary") |> render_click()
    assert has_element?(view, "#developer-controls[open]")
    send(view.pid, :sample)
    assert has_element?(view, "#developer-controls[open]")
    view |> element("#developer-controls summary") |> render_click()
    refute has_element?(view, "#developer-controls[open]")
  end

  test "renders pacing controls and saves runtime values", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/game-settings")

    assert html =~ "Game Pacing"
    assert html =~ "Save Pacing"

    params = %{
      "pacing" => %{
        "bot_delay_ms" => "2400",
        "bot_delay_variance_ms" => "500",
        "bot_min_delay_ms" => "700",
        "trick_transition_delay_ms" => "1600",
        "hand_transition_delay_ms" => "3500"
      }
    }

    _ = render_change(view, "update_pacing_form", params)
    assert render(view) =~ "Bots will act between 1900ms and 2900ms"

    _ = render_submit(view, "save_pacing", params)

    assert render(view) =~ "Bots will act between 1900ms and 2900ms"
    assert Lifecycle.config(:bot_delay_ms) == 2400
    assert Lifecycle.config(:bot_delay_variance_ms) == 500
    assert Lifecycle.config(:hand_transition_delay_ms) == 3500
  end

  test "reset restores lifecycle defaults from game settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/game-settings")

    _ =
      render_submit(view, "save_pacing", %{
        "pacing" => %{
          "bot_delay_ms" => "3000",
          "bot_delay_variance_ms" => "200",
          "bot_min_delay_ms" => "900",
          "trick_transition_delay_ms" => "2100",
          "hand_transition_delay_ms" => "4100"
        }
      })

    _ = render_click(view, "reset_pacing")

    defaults = Lifecycle.defaults()
    assert render(view) =~ "Bots will act between 2000ms and 2000ms"
    assert Lifecycle.config(:bot_delay_ms) == defaults.bot_delay_ms
    assert Lifecycle.config(:trick_transition_delay_ms) == defaults.trick_transition_delay_ms
  end

  test "ignores online count updates from lobby pubsub", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/games")

    assert html =~ "Game settings"
    refute has_element?(view, "#pacing-form")

    send(
      view.pid,
      {:online_count_updated, %{count: 1, breakdown: %{playing: 1, spectating: 0, lobby: 0}}}
    )

    assert render(view) =~ "Game settings"
  end

  test "actual seated public names resolve outside the recent twenty and follow joins/leaves", %{
    conn: conn
  } do
    host = PidroServer.AccountsFixtures.user_fixture(%{display_name: "Longtime player"})

    host
    |> Ecto.Changeset.change(inserted_at: ~U[2020-01-01 00:00:00.000000Z])
    |> PidroServer.Repo.update!()

    PidroServer.Repo.insert!(%PidroServer.Accounts.UserAvatar{
      user_id: host.id,
      version: "live-avatar",
      image: "private-image-bytes"
    })

    avatar_url = PidroServer.Accounts.Avatars.url("live-avatar", host.id)

    for _ <- 1..21, do: PidroServer.AccountsFixtures.user_fixture()
    refute Enum.any?(PidroServer.Accounts.Auth.list_recent_users(20), &(&1.id == host.id))
    {:ok, room} = RoomManager.create_room(host.id)
    {:ok, view, html} = live(conn, ~p"/admin/games")
    assert has_element?(view, "#room-#{room.code}", "Longtime player")
    assert has_element?(view, "#room-#{room.code} img[src='#{avatar_url}']")
    refute html =~ host.email
    refute html =~ "private-image-bytes"

    friend = PidroServer.AccountsFixtures.user_fixture(%{display_name: "New seated friend"})
    {:ok, _, _} = RoomManager.join_room(room.code, friend.id)
    assert has_element?(view, "#room-#{room.code}", "New seated friend")
    :ok = RoomManager.leave_room(friend.id)
    refute has_element?(view, "#room-#{room.code}", "New seated friend")
  end

  test "two real games update independently, including timers, turn, action and rematch", %{
    conn: conn
  } do
    Application.put_env(:pidro_server, Lifecycle, dealer_selection_delay_ms: 0)
    {one, ids} = playing_room()
    {two, _} = playing_room()
    {:ok, view, _} = live(conn, ~p"/admin/games")
    before_two = AdminGameSummary.get(two.code)
    assert has_element?(view, "#room-#{one.code}", "Dealer selection")

    {:ok, _} = GameAdapter.apply_action(one.code, :north, :select_dealer)
    eventually(fn -> assert AdminGameSummary.get(one.code).phase == :bidding end)
    eventually(fn -> assert has_element?(view, "#room-#{one.code}", "Bidding") end)
    refute has_element?(view, "#room-#{two.code}", "Bidding")
    assert AdminGameSummary.get(two.code) == before_two

    {:ok, state} = GameAdapter.get_state(one.code)
    {:ok, next} = GameAdapter.apply_action(one.code, state.current_turn, {:bid, 8})
    eventually(fn -> assert has_element?(view, "#room-#{one.code}", "Bid made") end)
    assert has_element?(view, "#room-#{one.code}", "(#{next.current_turn})")
    assert has_element?(view, "#room-#{one.code} time[datetime]")

    # No card-bearing payload can reach this view: it only receives lobby
    # lifecycle messages and samples this exact fixed public projection.
    summary = AdminGameSummary.get(one.code)

    assert Enum.sort(Map.keys(summary)) ==
             Enum.sort(
               ~w(phase current_turn trick_number cumulative_scores hand_number pace last_event updated_at)a
             )

    refute inspect(summary) =~ "hand:"
    refute render(view) =~ "revealed_cards"

    # Real game completion lifecycle and same-room rematch, not a mocked row event.
    send(RoomManager, {:game_over, one.code, :north_south, %{north_south: 62, east_west: 19}})
    {:ok, finished} = RoomManager.get_room(one.code)
    assert finished.status == :finished
    eventually(fn -> assert has_element?(view, "#room-#{one.code}", "Completed") end)
    {:ok, readiness} = RoomManager.readiness(one.code)

    for id <- ids,
        do:
          {:ok, _} =
            RoomManager.confirm_rematch(one.code, one.id, id, self(), readiness.ready_epoch)

    eventually(fn -> assert AdminGameSummary.get(one.code).phase == :dealer_selection end)
    eventually(fn -> assert has_element?(view, "#room-#{one.code}", "Dealer selection") end)
    assert AdminGameSummary.get(two.code) == before_two
    :ok = RoomManager.close_room(one.code)
    eventually(fn -> refute has_element?(view, "#room-#{one.code}") end)
    assert has_element?(view, "#room-#{two.code}")
  end

  test "own-pace hand holds are normal, and filters work on waiting rooms", %{
    conn: conn
  } do
    {room, _} = RoomFixtures.waiting_room_fixture(seated: 4)
    room = RoomFixtures.ready_room(room.code)
    {:ok, pid} = GameSupervisor.get_game(room.code)
    {:ok, state} = GameAdapter.get_state(room.code)

    held = %{
      state
      | phase: :hand_complete,
        config: %{pace: :own},
        cumulative_scores: %{north_south: 24, east_west: -8}
    }

    :ok = GenServer.call(pid, {:set_state, held})
    {:ok, view, _} = live(conn, ~p"/admin/games")
    assert has_element?(view, "#room-#{room.code}", "Waiting for Continue")
    assert has_element?(view, "#room-#{room.code}", "N/S 24 · E/W -8")
    refute has_element?(view, "#room-#{room.code}", "Connection / process issue")
    {:ok, waiting} = RoomManager.create_room("waiting-host")
    view |> form("#phase-filter-form", phase: "hand_complete") |> render_change()
    assert has_element?(view, "#room-#{room.code}")
    refute has_element?(view, "#room-#{waiting.code}")
    view |> form("#phase-filter-form", phase: "issues") |> render_change()
    refute has_element?(view, "#room-#{room.code}")
  end

  test "Waiting includes ready tables as well as partially seated rooms", %{conn: conn} do
    {full, _} = RoomFixtures.waiting_room_fixture(seated: 4)
    {:ok, waiting} = RoomManager.create_room("another-waiting-host")
    {:ok, view, _} = live(conn, ~p"/admin/games")
    ready = %{full | status: :ready}
    Phoenix.PubSub.broadcast(PidroServer.PubSub, "lobby:updates", {:room_updated, ready})

    assert has_element?(view, "#room-counts", "2 waiting")
    view |> form("#phase-filter-form", phase: "waiting") |> render_change()
    assert has_element?(view, "#room-#{ready.code}")
    assert has_element?(view, "#room-#{waiting.code}")
  end

  test "renders an ownerless room", %{conn: conn} do
    {:ok, room} = RoomManager.create_room("departed-host", %{name: "Ownerless Table"})
    set_room_owner(room.code, nil)

    {:ok, _view, html} = live(conn, ~p"/admin/games")

    assert html =~ "Ownerless Table"
    assert html =~ "No owner"
  end

  test "invitation creation and release leave the connected admin room list working", %{
    conn: conn
  } do
    host = PidroServer.AccountsFixtures.user_fixture()
    friend = PidroServer.AccountsFixtures.user_fixture()
    {:ok, view, _html} = live(conn, ~p"/admin/games")

    {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{south: friend.id}})
    room_link = "a[href='/admin/games/#{room.code}']"
    assert has_element?(view, room_link)

    {:ok, _} = RoomManager.set_seat_hold(room.code, host.id, :south, nil)
    assert has_element?(view, room_link)
    :ok = RoomManager.close_room(room.code)
    refute has_element?(view, room_link)
  end

  describe "room creation passes the room config constructor" do
    test "unavailable bot manager leaves the custom room and connected view usable", %{conn: conn} do
      manager = Process.whereis(PidroServer.Games.Bots.BotManager)

      on_exit(fn ->
        unless Process.whereis(PidroServer.Games.Bots.BotManager),
          do: Process.register(manager, PidroServer.Games.Bots.BotManager)
      end)

      Process.unregister(PidroServer.Games.Bots.BotManager)

      try do
        {:ok, view, _} = live(conn, ~p"/admin/games")
        render_click(view, "toggle_create_form")
        assert has_element?(view, "details[open] #create-game-form")

        view
        |> form("#create-game-form", %{
          game_name: "Bots unavailable",
          host_user_id: "dev_host",
          bot_count: "3",
          bot_difficulty: "random"
        })
        |> render_submit()

        assert [room] = RoomManager.list_rooms(:all)
        assert room.config.name == "Bots unavailable"
        assert render(view) =~ "Room #{room.code} created, but bots could not be started"
        view |> form("#phase-filter-form", phase: "waiting") |> render_change()
        assert has_element?(view, "#room-#{room.code}")
        assert Process.alive?(view.pid)
      after
        Process.register(manager, PidroServer.Games.Bots.BotManager)
      end
    end

    for preset <- ~w(preset_1h_3b preset_2h_2b preset_4_bots) do
      test "#{preset} warns instead of crashing when the bot manager is unavailable", %{
        conn: conn
      } do
        manager = Process.whereis(PidroServer.Games.Bots.BotManager)

        on_exit(fn ->
          unless Process.whereis(PidroServer.Games.Bots.BotManager),
            do: Process.register(manager, PidroServer.Games.Bots.BotManager)
        end)

        Process.unregister(PidroServer.Games.Bots.BotManager)

        try do
          {:ok, view, _} = live(conn, ~p"/admin/games")
          render_click(view, unquote(preset))
          assert [room] = RoomManager.list_rooms(:all)
          flash = assert_redirect(view, ~p"/admin/games/#{room.code}")
          assert flash["warning"] == "Room #{room.code} created, but bots could not be started"
        after
          Process.register(manager, PidroServer.Games.Bots.BotManager)
        end
      end
    end

    for preset <- ~w(preset_empty_room preset_1h_3b preset_2h_2b preset_4_bots) do
      test "AE6: #{preset} creates a room with a valid config and no free-form key", %{
        conn: conn
      } do
        {:ok, view, _html} = live(conn, ~p"/admin/games")

        render_click(view, unquote(preset))

        assert [room] = RoomManager.list_rooms(:all)
        assert %Config{name: "Dev " <> _, bot_difficulty: :random, solo: false} = room.config
        assert Config.new(room.config) == {:ok, room.config}
        refute Map.has_key?(room, :metadata)
      end
    end

    test "the create form stores the chosen name and difficulty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/games")

      render_hook(view, "create_game", %{
        "game_name" => "Form Table",
        "bot_count" => "0",
        "bot_difficulty" => "smart",
        "host_user_id" => "dev_host"
      })

      assert [room] = RoomManager.list_rooms(:all)
      assert room.config == %Config{name: "Form Table", bot_difficulty: :smart, solo: false}
    end
  end

  # Room 7NTI, 2026-11-04: three players drop, the host comes back, south and
  # west are gone for good; after game over east leaves and the host's
  # channel closes `left`. The table must not be left looking broken.
  test "a finished table its players walk away from leaves no stale seats", %{conn: conn} do
    require Phoenix.ChannelTest
    import Phoenix.ChannelTest, only: [subscribe_and_join: 3, leave: 1]

    users = for _ <- 1..4, do: PidroServer.AccountsFixtures.user_fixture()
    [host, east, south, west] = Enum.map(users, & &1.id)
    {:ok, room} = RoomManager.create_room(host)
    for id <- [east, south, west], do: {:ok, _, _} = RoomManager.join_room(room.code, id)
    code = RoomFixtures.ready_room(room.code).code

    {:ok, socket} =
      Phoenix.ChannelTest.connect(PidroServerWeb.UserSocket, %{
        "token" => PidroServer.Accounts.Token.generate(hd(users))
      })

    {:ok, _, host_channel} =
      subscribe_and_join(socket, PidroServerWeb.GameChannel, "game:#{code}")

    for id <- [host, south, west], do: :ok = RoomManager.handle_player_disconnect(code, id)
    for pos <- [:north, :south, :west], do: expire_phase(code, pos, :phase2_start)
    {:ok, _} = RoomManager.handle_player_reconnect(code, host)
    for pos <- [:south, :west], do: expire_phase(code, pos, :phase3_gone)

    # Long enough an absence window to look at the table inside it.
    lifecycle = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.put(lifecycle, :hiccup_timeout_ms, 1_000)
    )

    send(RoomManager, {:game_over, code, :north_south, %{north_south: 62, east_west: 40}})

    conn
    |> put_req_header(
      "authorization",
      "Bearer #{PidroServer.Accounts.Token.generate(Enum.at(users, 1))}"
    )
    |> delete(~p"/api/v1/rooms/#{code}/leave")
    |> response(204)

    # Only the host's real channel is left; it leaves the way the app does.
    RoomManager.unregister_game_channel(code, host, self())
    Process.unlink(host_channel.channel_pid)
    closed = Process.monitor(host_channel.channel_pid)
    leave(host_channel)
    assert_receive {:DOWN, ^closed, :process, _, {:shutdown, :left}}
    :sys.get_state(RoomManager)

    {:ok, reopened} = RoomManager.get_room(code)
    assert reopened.status == :waiting

    for {_position, seat} <- reopened.seats do
      refute seat.status in [:reconnecting, :grace]
      assert seat.grace_expires_at == nil
      assert seat.bot_pid == nil
    end

    assert substitute_bots(code) == []

    # South's and west's grace deadlines, had they kept them, are past now.
    Process.sleep(Lifecycle.config(:grace_timeout_ms))

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        send(RoomManager, :health_check)
        :sys.get_state(RoomManager)
      end)

    refute log =~ "expired grace period"

    {:ok, view, _} = live(conn, ~p"/admin/games")
    assert has_element?(view, "#room-#{code}")
    refute has_element?(view, "#room-#{code}", "Connection / process issue")

    # The host walked away from a table with nobody else at it: it closes.
    eventually(fn -> assert {:error, :room_not_found} = RoomManager.get_room(code) end)
  end

  test "a reopened table starts its next game with its substitutes playing" do
    {room, [_host, east, south, _west]} = playing_room()
    :ok = RoomManager.handle_player_disconnect(room.code, south)
    expire_phase(room.code, :south, :phase2_start)
    expire_phase(room.code, :south, :phase3_gone)
    send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 40}})
    :ok = RoomManager.leave_room(east)
    assert substitute_bots(room.code) == []

    newcomer = PidroServer.AccountsFixtures.user_fixture().id
    {:ok, _, :east} = RoomManager.join_room(room.code, newcomer)
    {:ok, playing} = RoomManager.get_room(room.code)
    playing = if playing.status == :playing, do: playing, else: RoomFixtures.ready_room(room.code)

    assert playing.status == :playing
    assert [pid] = substitute_bots(room.code)
    assert playing.seats.south.bot_pid == pid
  end

  defp expire_phase(code, position, phase),
    do: PidroServer.RoomManagerCase.expire_phase(code, position, phase)

  defp substitute_bots(code) do
    for {_, pid, _, [PidroServer.Games.Bots.SubstituteBot]} <-
          DynamicSupervisor.which_children(PidroServer.Games.Bots.BotSupervisor),
        is_pid(pid),
        :sys.get_state(pid).room_code == code,
        do: pid
  end

  defp set_room_owner(room_code, host_id) do
    :sys.replace_state(RoomManager, fn state ->
      update_in(state.rooms[room_code], &%{&1 | host_id: host_id})
    end)
  end

  defp playing_room do
    [host | others] = users = for _ <- 1..4, do: PidroServer.AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id)
    for user <- others, do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
    {RoomFixtures.ready_room(room.code), Enum.map(users, & &1.id)}
  end

  defp eventually(assertion, remaining \\ 40) do
    assertion.()
  rescue
    error in [ExUnit.AssertionError] ->
      if remaining == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(50)
      eventually(assertion, remaining - 1)
  end
end
