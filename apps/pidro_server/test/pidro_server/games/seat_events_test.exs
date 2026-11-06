defmodule PidroServer.Games.SeatEventsTest do
  @moduledoc """
  The seat events behind the beta report: a drop starts the two-minute
  cascade, a return reclaims the seat inside it, a timed turn records how long
  the player took, and a timeout records that the clock ran out. Each is
  recorded once, at that moment, and nowhere else.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.{GameAdapter, Lifecycle, RoomManager}
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Stats.SeatEvent
  import PidroServer.RoomManagerCase, only: [expire_phase: 3]

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
      nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    previous = Application.get_env(:pidro_server, Lifecycle, [])

    # Nothing fires by itself: the tests expire phases and turns by hand.
    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.merge(previous,
        hiccup_timeout_ms: 600_000,
        grace_timeout_ms: 1_200_000,
        turn_timer_bid_ms: 600_000,
        turn_timer_play_ms: 600_000,
        deal_transition_delay_ms: 0
      )
    )

    on_exit(fn ->
      PidroServer.RoomManagerCase.cleanup()
      Application.put_env(:pidro_server, Lifecycle, previous)
    end)

    :ok
  end

  describe "drops and returns" do
    @tag :table_outcomes
    test "an admin-applied turn excludes an incompletely counted table" do
      {room, user} = bidding_room()
      assert {:ok, _} = GameAdapter.apply_action(room.code, position_of(room, user), :pass)
      RoomManager.get_room(room.code)
      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 25}})
      RoomManager.get_room(room.code)
      await_tasks()
      assert Repo.aggregate(PidroServer.Stats.TableOutcome, :count) == 0
    end

    @tag :pause_review
    test "a slow substitute cannot outlast the original turn's pause allowance" do
      pause_budget(250)

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(Application.fetch_env!(:pidro_server, Lifecycle),
          hiccup_timeout_ms: 200,
          bot_delay_ms: 5_000
        )
      )

      {room, user} = bidding_room()
      position = position_of(room, user)
      {:ok, original} = GameAdapter.get_state(room.code)
      :ok = RoomManager.handle_player_disconnect(room.code, user)

      wait_until(fn ->
        {:ok, current} = RoomManager.get_room(room.code)
        current.seats[position].status == :bot_substitute
      end)

      wait_until(
        fn ->
          {:ok, current} = GameAdapter.get_state(room.code)
          length(current.events) > length(original.events)
        end,
        20
      )

      assert {:ok, returned} = RoomManager.handle_player_reconnect(room.code, user)
      assert returned.seats[position].user_id == user
      assert PidroServer.Stats.list_abandonments_for_room(room.code) == []
    end

    @tag :pause_review
    test "one human with original bots retains its background hold" do
      pause_budget(80)
      {:ok, room} = RoomManager.create_room("solo-style", %{})
      for pos <- [:east, :south, :west], do: BotManager.start_bot(room.code, pos, :basic, 1)
      PidroServer.RoomFixtures.ready_room(room.code)
      {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)

      wait_until(fn ->
        match?({:ok, %{phase: :bidding, current_turn: :north}}, GameAdapter.get_state(room.code))
      end)

      {:ok, before} = GameAdapter.get_state(room.code)
      :ok = RoomManager.going_background(room.code, "solo-style")
      Process.sleep(140)
      assert {:ok, ^before} = GameAdapter.get_state(room.code)
      :ok = RoomManager.register_game_channel(room.code, "solo-style", self())
      assert {:ok, %{turn_timer: timer}} = RoomManager.get_room(room.code)
      assert timer != nil
    end

    for {ending, expected} <- [finished: 100, peer_left: 0, closed: 0] do
      @tag :table_outcomes
      test "human, timer and stand-in turns persist once when the table is #{ending}" do
        {room, user} = bidding_room()

        for id <- Map.values(room.positions) do
          :ok =
            RoomManager.register_game_channel(room.code, id, self(), %{
              platform: "android",
              app_version: "3.2.4"
            })
        end

        position = position_of(room, user)

        assert {:ok, _} =
                 RoomManager.apply_player_action(room.code, user, position, :pass, %{
                   action_id: "once"
                 })

        assert {:ok, _} =
                 RoomManager.apply_player_action(room.code, user, position, :pass, %{
                   action_id: "once"
                 })

        wait_until(fn ->
          {:ok, next} = RoomManager.get_room(room.code)
          next.turn_timer && next.turn_timer.key != room.turn_timer.key
        end)

        {:ok, next} = RoomManager.get_room(room.code)
        timer = next.turn_timer
        send(RoomManager, {:turn_timer_expired, room.code, timer.timer_id, timer.key})

        wait_until(fn ->
          {:ok, next} = RoomManager.get_room(room.code)
          next.turn_timer && next.turn_timer.key != timer.key
        end)

        {:ok, next} = RoomManager.get_room(room.code)
        position = next.turn_timer.actor_position
        absent = next.positions[position]
        :ok = RoomManager.handle_player_disconnect(room.code, absent)
        {:ok, covered} = expire_phase(room.code, position, :phase2_start)
        {:ok, before} = GameAdapter.get_state(room.code)
        send(covered.seats[position].bot_pid, :make_move)

        wait_until(fn ->
          {:ok, current} = GameAdapter.get_state(room.code)
          length(current.events) > length(before.events)
        end)

        if unquote(ending) == :peer_left, do: RoomManager.leave_room(user)

        if unquote(ending) == :closed do
          RoomManager.close_room(room.code)
        else
          send(
            RoomManager,
            {:game_over, room.code, :north_south, %{north_south: 62, east_west: 25}}
          )

          RoomManager.get_room(room.code)

          send(
            RoomManager,
            {:game_over, room.code, :north_south, %{north_south: 62, east_west: 25}}
          )

          RoomManager.get_room(room.code)
        end

        await_tasks()
        assert [row] = PidroServer.Stats.connection_analytics(7)
        assert row.turns == 3
        assert row.bot_turns == 2
        assert row.takeover_games == 1
        assert row.others_finished_percent == unquote(expected)
      end
    end

    @tag :pause_budget
    test "repeated drop and return spends one pause allowance in a turn" do
      pause_budget(240)
      {room, user} = bidding_room()
      {:ok, original} = GameAdapter.get_state(room.code)

      for _ <- 1..2 do
        :ok = RoomManager.handle_player_disconnect(room.code, user)
        Process.sleep(85)
        assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      end

      :ok = RoomManager.handle_player_disconnect(room.code, user)

      wait_until(
        fn ->
          {:ok, current} = GameAdapter.get_state(room.code)
          length(current.events) > length(original.events)
        end,
        20
      )

      assert {:ok, returned} = RoomManager.handle_player_reconnect(room.code, user)
      assert returned.seats[position_of(room, user)].user_id == user
      refute Map.has_key?(returned.consecutive_timeouts, position_of(room, user))
    end

    @tag :pause_budget
    test "background hold and subsequent drop share the turn allowance" do
      pause_budget(240)
      {room, user} = bidding_room()
      {:ok, original} = GameAdapter.get_state(room.code)
      :ok = RoomManager.going_background(room.code, user)
      Process.sleep(170)
      {:ok, held} = RoomManager.get_room(room.code)
      token = held.seats[position_of(room, user)].background_token
      send(RoomManager, {:background_expired, room.code, user, token})

      wait_until(
        fn ->
          {:ok, current} = GameAdapter.get_state(room.code)
          length(current.events) > length(original.events)
        end,
        20
      )

      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      assert PidroServer.Stats.list_abandonments_for_room(room.code) == []
    end

    @tag :pause_budget
    test "return resumes inside the allowance and the next turn gets a fresh allowance" do
      pause_budget(240)
      {room, user} = bidding_room()
      :ok = RoomManager.handle_player_disconnect(room.code, user)
      Process.sleep(170)
      assert {:ok, returned} = RoomManager.handle_player_reconnect(room.code, user)
      assert returned.turn_timer.duration_ms > 500_000

      assert {:ok, _} =
               RoomManager.apply_player_action(room.code, user, position_of(room, user), :pass)

      wait_until(fn ->
        {:ok, next} = RoomManager.get_room(room.code)
        next.turn_timer && next.turn_timer.key != returned.turn_timer.key
      end)

      {:ok, next} = RoomManager.get_room(room.code)
      actor = next.positions[next.turn_timer.actor_position]
      {:ok, original} = GameAdapter.get_state(room.code)
      :ok = RoomManager.handle_player_disconnect(room.code, actor)
      Process.sleep(130)
      assert {:ok, ^original} = GameAdapter.get_state(room.code)

      wait_until(fn ->
        {:ok, current} = GameAdapter.get_state(room.code)
        length(current.events) > length(original.events)
      end)
    end

    @tag :pause_budget
    test "resume floor spends allowance rather than manufacturing ten seconds" do
      pause_budget(240)
      {room, user} = bidding_room()

      :sys.replace_state(RoomManager, fn state ->
        put_in(
          state.rooms[room.code].turn_timer.deadline_mono,
          System.monotonic_time(:millisecond) + 100
        )
      end)

      :ok = RoomManager.handle_player_disconnect(room.code, user)
      assert {:ok, returned} = RoomManager.handle_player_reconnect(room.code, user)
      assert returned.turn_timer.duration_ms <= 340
      {:ok, original} = GameAdapter.get_state(room.code)
      :ok = RoomManager.handle_player_disconnect(room.code, user)

      wait_until(fn ->
        {:ok, current} = GameAdapter.get_state(room.code)
        length(current.events) > length(original.events)
      end)
    end

    test "activity satisfies liveness without discarding the outstanding RTT measurement" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: id}}
      :ok = RoomManager.connection_activity(room.code, user, id)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: _}}
      :ok = RoomManager.connection_activity(room.code, user)

      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: _}}
      assert {:ok, active} = RoomManager.get_room(room.code)
      assert active.seats[position].missed_pings == 0
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: _}}
      assert {:ok, active} = RoomManager.get_room(room.code)
      assert active.seats[position].status == :connected
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: _}}
      assert {:ok, absent} = RoomManager.get_room(room.code)
      assert absent.seats[position].status == :reconnecting
    end

    test "activity preserves a pong's measurement and finalization counts an unanswered probe" do
      {room, user} = bidding_room()
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: id}}
      :ok = RoomManager.connection_activity(room.code, user)
      :ok = RoomManager.connection_activity(room.code, user, id)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: _}}
      :ok = RoomManager.handle_player_disconnect(room.code, user)
      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 25}})
      assert {:ok, finished} = RoomManager.get_room(room.code)
      await_tasks()
      assert [saved] = PidroServer.Stats.connection_games(user)
      assert saved.checks_sent == 2
      assert saved.unanswered_checks == 1
      assert is_number(saved.median_ms)
      seat = finished.seats[position_of(room, user)]

      totals =
        PidroServer.Games.Room.Seat.connection_totals(
          seat,
          System.system_time(:millisecond) + 3_600_000
        )

      assert totals.duration_seconds == saved.duration_seconds
      assert totals.disconnected_seconds == saved.disconnected_seconds
    end

    test "game end saves one connection aggregate per player and game" do
      {room, user} = bidding_room()

      :ok =
        RoomManager.register_game_channel(room.code, user, self(), %{
          app_version: "3.2.4",
          platform: "android",
          network: "cellular"
        })

      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: id}}
      :ok = RoomManager.connection_activity(room.code, user, id)
      :ok = RoomManager.handle_player_disconnect(room.code, user)
      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 25}})
      RoomManager.get_room(room.code)
      await_tasks()

      assert [saved] = PidroServer.Stats.connection_games(user)
      assert saved.room_code == room.code
      assert saved.checks_sent == 1
      assert saved.unanswered_checks == 0
      assert saved.drops == 1
      assert is_number(saved.median_ms)
      assert saved.p95_ms >= saved.median_ms
      assert saved.network == "cellular"
      assert saved.app_version == "3.2.4"
      assert saved.platform == "android"

      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 25}})
      RoomManager.get_room(room.code)
      await_tasks()
      assert [_] = PidroServer.Stats.connection_games(user)
    end

    test "leaving writes the player's aggregate without waiting for game over" do
      {room, user} = bidding_room()
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: id}}
      :ok = RoomManager.connection_activity(room.code, user, id)
      :ok = RoomManager.leave_room(room.code, user)
      await_tasks()

      assert [saved] = PidroServer.Stats.connection_games(user)
      assert saved.checks_sent == 1
      assert saved.drops == 0
      assert is_number(saved.median_ms)
      assert {:ok, %{status: :playing}} = RoomManager.get_room(room.code)

      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 25}})
      RoomManager.get_room(room.code)
      await_tasks()
      assert [^saved] = PidroServer.Stats.connection_games(user)
    end

    test "two missed probes pause a seat only after its first pong" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      :ok = RoomManager.register_game_channel(room.code, user, self())

      for _ <- 1..3 do
        expire_connection_checks()
        assert_receive {:connection_ping, ^user, %{id: _}}
      end

      assert {:ok, connected} = RoomManager.get_room(room.code)
      assert connected.seats[position].status == :connected
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: id}}
      assert :ok = GenServer.call(RoomManager, {:connection_pong, room.code, user, id})

      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: _}}
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: _}}
      assert {:ok, connected} = RoomManager.get_room(room.code)
      assert connected.seats[position].status == :connected
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: last}}
      assert {:ok, dropped} = RoomManager.get_room(room.code)
      assert dropped.seats[position].status == :reconnecting
      assert dropped.turn_timer == nil
      assert :ok = GenServer.call(RoomManager, {:connection_pong, room.code, user, last})
      assert {:ok, returned} = RoomManager.get_room(room.code)
      assert returned.seats[position].status == :connected
      assert returned.turn_timer.duration_ms >= 10_000
      assert seat_events(user) == [{"drop", nil}, {"return", nil}]
    end

    test "an unreachable turn never triggers the consecutive-timeout penalty" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      # A periodic probe may arrive before the test forces the next tick.
      send(RoomManager, :check_connections)
      RoomManager.get_room(room.code)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: id}}
      :ok = RoomManager.connection_activity(room.code, user, id)

      :sys.replace_state(RoomManager, fn state ->
        put_in(state.rooms[room.code].consecutive_timeouts, %{position => 2})
      end)

      timer = room.turn_timer
      send(RoomManager, {:turn_timer_expired, room.code, timer.timer_id, timer.key})
      assert {:ok, timed_out} = RoomManager.get_room(room.code)
      assert timed_out.consecutive_timeouts[position] == 3
      refute_receive {:force_disconnect, :timeout_threshold}

      for _ <- 1..3 do
        expire_connection_checks()
        assert_receive {:connection_ping, ^user, %{id: _}}
      end

      assert {:ok, disconnected} = RoomManager.get_room(room.code)
      assert disconnected.seats[position].status == :reconnecting
      assert Map.get(disconnected.consecutive_timeouts, position, 0) == 0
      refute_receive {:force_disconnect, :timeout_threshold}
    end

    test "a reachable idle player still reaches the timeout threshold" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: id}}
      :ok = RoomManager.connection_activity(room.code, user, id)

      :sys.replace_state(RoomManager, fn state ->
        put_in(state.rooms[room.code].consecutive_timeouts, %{position => 2})
      end)

      timer = room.turn_timer
      send(RoomManager, {:turn_timer_expired, room.code, timer.timer_id, timer.key})
      RoomManager.get_room(room.code)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: next}}
      :ok = RoomManager.connection_activity(room.code, user, next)
      assert_receive {:force_disconnect, :timeout_threshold}
    end

    test "connection probes use the configured reply window without penalizing a short gap" do
      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.put(
          Application.fetch_env!(:pidro_server, Lifecycle),
          :connection_check_interval_ms,
          500
        )
      )

      {room, user} = bidding_room()
      position = position_of(room, user)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: first}}
      :ok = RoomManager.connection_activity(room.code, user, first)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: pending}}

      send(RoomManager, :check_connections)
      assert {:ok, fresh} = RoomManager.get_room(room.code)
      assert fresh.seats[position].pending_ping.id == pending

      :sys.replace_state(RoomManager, fn state ->
        put_in(
          state.rooms[room.code].seats[position].pending_ping.sent_at,
          System.monotonic_time(:millisecond) - 501
        )
      end)

      send(RoomManager, :check_connections)
      assert_receive {:connection_ping, ^user, %{id: next}}
      refute next == pending
      assert {:ok, connected} = RoomManager.get_room(room.code)
      assert connected.seats[position].status == :connected
      :ok = RoomManager.connection_activity(room.code, user, next)
      refute_receive {:force_disconnect, :timeout_threshold}
    end

    test "queued check ticks cannot spend a fresh probe's reply window" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: id}}
      :ok = RoomManager.connection_activity(room.code, user, id)
      expire_connection_checks()
      assert_receive {:connection_ping, ^user, %{id: fresh}}
      for _ <- 1..3, do: send(RoomManager, :check_connections)
      assert {:ok, connected} = RoomManager.get_room(room.code)
      assert connected.seats[position].status == :connected
      assert connected.seats[position].pending_ping.id == fresh
      :ok = RoomManager.connection_activity(room.code, user, fresh)
      assert {:ok, answered} = RoomManager.get_room(room.code)
      assert length(answered.seats[position].round_trips) == 2
    end

    test "game over retires a background hold before later socket loss" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      :ok = RoomManager.going_background(room.code, user)
      {:ok, held} = RoomManager.get_room(room.code)
      token = held.seats[position].background_token
      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 20}})
      assert {:ok, finished} = RoomManager.get_room(room.code)
      assert finished.status == :finished
      assert finished.seats[position].background_token == nil
      assert RoomManager.unregister_game_channel(room.code, user, self()) == :last_channel_closed
      send(RoomManager, {:background_expired, room.code, user, token})
      RoomManager.get_room(room.code)
      absence = :sys.get_state(RoomManager).finished_absences[{room.code, user}]
      assert is_reference(absence)
      send(RoomManager, {:finished_absence, room.code, user, absence, :finished})
      assert {:ok, reopened} = RoomManager.get_room(room.code)
      refute user in Map.values(reopened.positions)
    end

    test "background holds quietly through socket loss, but expires into a normal drop" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      :ok = RoomManager.register_game_channel(room.code, user, self())
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      assert :ok = GenServer.call(RoomManager, {:going_background, room.code, user})
      assert {:ok, held} = RoomManager.get_room(room.code)
      assert held.turn_timer == nil
      assert held.seats[position].status == :connected
      assert RoomManager.unregister_game_channel(room.code, user, self()) == :last_channel_closed
      assert {:ok, held} = RoomManager.get_room(room.code)
      assert held.seats[position].status == :connected
      assert seat_events(user) == []
      refute_receive {:player_reconnecting, _}

      :ok = RoomManager.register_game_channel(room.code, user, self())
      assert {:ok, returned} = RoomManager.get_room(room.code)
      assert returned.turn_timer != nil
      assert seat_events(user) == []
      assert :ok = GenServer.call(RoomManager, {:going_background, room.code, user})
      assert {:ok, held} = RoomManager.get_room(room.code)
      token = held.seats[position].background_token
      send(RoomManager, {:background_expired, room.code, user, token})
      assert {:ok, dropped} = RoomManager.get_room(room.code)
      assert dropped.seats[position].status == :reconnecting
      assert seat_events(user) == [{"drop", nil}]
    end

    test "a late tap identifies the action the timer played for that exact turn" do
      {room, user} = bidding_room()
      timer = room.turn_timer
      {:ok, snapshot} = GameAdapter.get_snapshot(room.code)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      context = %{
        action_id: "late",
        expected_turn: {snapshot.game_instance_id, length(snapshot.state.events)}
      }

      send(RoomManager, {:turn_timer_expired, room.code, timer.timer_id, timer.key})
      RoomManager.get_room(room.code)
      assert_receive {:turn_auto_played, %{action: action}}

      assert {:error, {:already_played_for_you, ^action}} =
               RoomManager.apply_player_action(
                 room.code,
                 user,
                 timer.actor_position,
                 :pass,
                 context
               )
    end

    test "rejoin records the connection's reason and network on the return" do
      {room, user} = bidding_room()
      :ok = RoomManager.handle_player_disconnect(room.code, user)

      :ok =
        RoomManager.register_game_channel(room.code, user, self(), %{
          reason: "heartbeat_timeout",
          network: "cellular",
          app_version: "3.2.4",
          platform: "android"
        })

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      await_tasks()
      returned = Repo.one!(from e in SeatEvent, where: e.user_id == ^user and e.kind == "return")
      assert Map.get(returned, :reason) == "heartbeat_timeout"
      assert Map.get(returned, :network) == "cellular"
      assert returned.app_version == "3.2.4"
    end

    test "failed abandonment persistence cannot interrupt finished or unrelated rooms" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      :ok = RoomManager.handle_player_disconnect(room.code, user)
      {:ok, substituted} = expire_phase(room.code, position, :phase2_start)
      bot = substituted.seats[position].bot_pid
      {:ok, other} = RoomManager.create_room("unrelated", %{})
      manager = Process.whereis(RoomManager)
      await_tasks()

      # Transactional DDL is rolled back with this test's sandbox.
      Repo.query!("DROP TABLE abandonment_events")

      assert ExUnit.CaptureLog.capture_log(fn ->
               send(
                 RoomManager,
                 {:game_over, room.code, :north_south, %{north_south: 62, east_west: 20}}
               )

               assert {:ok, finished} = RoomManager.get_room(room.code)
               assert finished.status == :finished
               assert finished.seats[position].bot_pid == nil
               refute Process.alive?(bot)
               assert Process.whereis(RoomManager) == manager
               assert {:ok, _, _} = RoomManager.join_room(other.code, "another")
             end) =~ "Failed to persist completed game"
    end

    @tag :flaky_connections
    test "only players still absent at game over get abandonment records" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      other = Enum.find(Map.values(room.positions), &(&1 != user))
      :ok = RoomManager.handle_player_disconnect(room.code, user)
      expire_phase(room.code, position, :phase2_start)
      expire_phase(room.code, position, :phase3_gone)
      assert PidroServer.Stats.list_abandonments_for_room(room.code) == []
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      :ok = RoomManager.handle_player_disconnect(room.code, other)
      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 20}})
      {:ok, finished} = RoomManager.get_room(room.code)
      assert finished.status == :finished
      assert [%{user_id: ^other}] = PidroServer.Stats.list_abandonments_for_room(room.code)
      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 20}})
      RoomManager.get_room(room.code)
      assert [%{user_id: ^other}] = PidroServer.Stats.list_abandonments_for_room(room.code)
    end

    @tag :flaky_connections
    test "seat events retain the joining app version and platform" do
      {room, user} = bidding_room()

      assert :ok =
               RoomManager.register_game_channel(room.code, user, self(), %{
                 app_version: "3.2.3",
                 platform: "android"
               })

      assert :ok = RoomManager.handle_player_disconnect(room.code, user)
      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      await_tasks()
      events = Repo.all(from e in SeatEvent, where: e.user_id == ^user)
      assert Enum.sort(Enum.map(events, & &1.kind)) == ["drop", "return"]

      assert Enum.all?(
               events,
               &(Map.get(&1, :app_version) == "3.2.3" and Map.get(&1, :platform) == "android")
             )
    end

    @tag :flaky_connections
    test "L5V3 four short drops then a 60 second drop never forfeit the seat" do
      {room, user} = bidding_room()
      position = position_of(room, user)

      for _ <- 1..4 do
        assert :ok = RoomManager.handle_player_disconnect(room.code, user)
        assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      end

      assert :ok = RoomManager.handle_player_disconnect(room.code, user)

      :sys.replace_state(RoomManager, fn state ->
        put_in(
          state.rooms[room.code].seats[position].disconnected_at,
          DateTime.add(DateTime.utc_now(), -60, :second)
        )
      end)

      {:ok, substituted} = expire_phase(room.code, position, :phase2_start)
      ref = substituted.phase_timers[position] || make_ref()
      send(RoomManager, {:timeout, ref, {:phase3_gone, room.code, position}})
      assert {:ok, returned} = RoomManager.handle_player_reconnect(room.code, user)
      assert returned.seats[position].user_id == user
      assert returned.seats[position].status == :connected
      refute user in returned.spectator_ids
      assert PidroServer.Stats.list_abandonments_for_room(room.code) == []
    end

    @tag :flaky_connections
    test "reconnecting pauses the turn and resumes with at least ten seconds" do
      {room, user} = bidding_room()
      timer = room.turn_timer
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :sys.replace_state(RoomManager, fn state ->
        put_in(
          state.rooms[room.code].turn_timer.deadline_mono,
          System.monotonic_time(:millisecond) + 100
        )
      end)

      assert :ok = RoomManager.handle_player_disconnect(room.code, user)
      assert {:ok, nil} = RoomManager.get_turn_timer(room.code)
      assert_receive {:turn_timer_cancelled, %{reason: :disconnected}}
      send(RoomManager, {:turn_timer_expired, room.code, timer.timer_id, timer.key})
      assert {:ok, _} = RoomManager.get_room(room.code)
      assert seat_events(user) == [{"drop", nil}]
      assert {:ok, returned} = RoomManager.handle_player_reconnect(room.code, user)
      assert returned.turn_timer.duration_ms == 10_000
      assert_receive {:turn_timer_started, %{duration_ms: 10_000}}
    end

    @tag :flaky_connections
    test "duplicate action_id after reconnect returns success without a second move" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      context = %{user_id: user, action_id: "retry-tap"}

      assert {:ok, original} =
               RoomManager.apply_player_action(room.code, user, position, :pass, context)

      assert :ok = RoomManager.handle_player_disconnect(room.code, user)
      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)

      assert {:ok, ^original} =
               RoomManager.apply_player_action(room.code, user, position, :pass, context)

      assert {:ok, current} = GameAdapter.get_state(room.code)
      assert current == original
      assert Enum.count(seat_events(user), fn {kind, _} -> kind == "turn" end) == 1
    end

    test "a drop mid-game and a return inside the hiccup are each recorded once" do
      {room, user} = bidding_room()

      assert :ok = RoomManager.handle_player_disconnect(room.code, user)
      assert seat_events(user) == [{"drop", nil}]

      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      assert seat_events(user) == [{"drop", nil}, {"return", nil}]
    end

    test "a return after a computer took the seat, inside the grace period, is recorded" do
      {room, user} = bidding_room()
      position = position_of(room, user)

      assert :ok = RoomManager.handle_player_disconnect(room.code, user)
      expire_phase(room.code, position, :phase2_start)
      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)

      assert seat_events(user) == [
               {"bot_took_seat", nil},
               {"drop", nil},
               {"return", nil},
               {"seat_taken_back", nil}
             ]
    end

    test "a player gone past the grace period can still return" do
      {room, user} = bidding_room()
      position = position_of(room, user)

      assert :ok = RoomManager.handle_player_disconnect(room.code, user)
      expire_phase(room.code, position, :phase2_start)
      expire_phase(room.code, position, :phase3_gone)

      assert {:ok, _} =
               RoomManager.handle_player_reconnect(room.code, user)

      assert seat_events(user) == [
               {"bot_took_seat", nil},
               {"drop", nil},
               {"return", nil},
               {"seat_taken_back", nil}
             ]
    end

    test "a seat held in a waiting room is neither a drop nor a return" do
      {:ok, room} = RoomManager.create_room("host", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "guest")

      assert :ok = RoomManager.handle_player_disconnect(room.code, "guest")
      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, "guest")

      assert seat_events("guest") == []
    end
  end

  describe "timed turns" do
    test "a turn taken on the clock records how long it took" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      Process.sleep(60)

      assert {:ok, _} = RoomManager.apply_player_action(room.code, user, position, :pass)

      assert [{"turn", elapsed_ms}] = seat_events(user)
      assert elapsed_ms >= 60 and elapsed_ms < 5_000
    end

    test "a turn taken after a drop and return counts from when the turn opened" do
      {room, user} = bidding_room()
      position = position_of(room, user)
      Process.sleep(60)

      assert :ok = RoomManager.handle_player_disconnect(room.code, user)
      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      assert {:ok, _} = RoomManager.apply_player_action(room.code, user, position, :pass)

      assert [{"drop", nil}, {"return", nil}, {"turn", elapsed_ms}] = seat_events(user)
      assert elapsed_ms >= 60
    end

    test "a turn the clock ran out on is a timeout, not a turn" do
      {room, user} = bidding_room()
      {:ok, room} = RoomManager.get_room(room.code)
      timer = room.turn_timer

      send(RoomManager, {:turn_timer_expired, room.code, timer.timer_id, timer.key})
      # The call queues behind the expiry, so the timeout has been handled.
      {:ok, _} = RoomManager.get_room(room.code)

      assert [{"timeout", elapsed_ms}] = seat_events(user)
      assert elapsed_ms >= 0
    end

    test "a solo game has no clock and records no turns" do
      {:ok, room} = RoomManager.create_room("solo", %{solo: true})
      for pos <- [:east, :south, :west], do: BotManager.start_bot(room.code, pos, :basic, 1)
      PidroServer.RoomFixtures.ready_room(room.code)
      {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)

      wait_until(fn ->
        match?({:ok, %{phase: :bidding, current_turn: :north}}, GameAdapter.get_state(room.code))
      end)

      {:ok, [action | _]} = GameAdapter.get_legal_actions(room.code, :north)
      assert {:ok, _} = RoomManager.apply_player_action(room.code, "solo", :north, action)
      assert seat_events("solo") == []
    end
  end

  defp pause_budget(ms) do
    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.put(Application.fetch_env!(:pidro_server, Lifecycle), :turn_pause_budget_ms, ms)
    )
  end

  defp expire_connection_checks do
    expired =
      :sys.replace_state(RoomManager, fn state ->
        rooms =
          Map.new(state.rooms, fn {code, room} ->
            seats =
              Map.new(room.seats, fn {position, seat} ->
                ping =
                  if seat.pending_ping,
                    do: %{
                      seat.pending_ping
                      | sent_at: System.monotonic_time(:millisecond) - 15_001
                    }

                {position, %{seat | pending_ping: ping}}
              end)

            {code, %{room | seats: seats}}
          end)

        %{state | rooms: rooms}
      end)

    for {_code, room} <- expired.rooms,
        {_position, %{pending_ping: %{id: id}}} <- room.seats do
      receive do
        {:connection_ping, _user, %{id: ^id}} -> :ok
      after
        0 -> :ok
      end
    end

    send(RoomManager, :check_connections)
  end

  # A four-player table in bidding, and the player whose turn it is.
  defp bidding_room do
    {:ok, room} = RoomManager.create_room("user1", %{})

    for user <- ["user2", "user3", "user4"],
        do: {:ok, _, _} = RoomManager.join_room(room.code, user)

    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)

    wait_until(fn ->
      match?({:ok, %{turn_timer: %{scope: :seat}}}, RoomManager.get_room(room.code))
    end)

    {:ok, room} = RoomManager.get_room(room.code)
    {room, room.positions[room.turn_timer.actor_position]}
  end

  defp position_of(room, user) do
    Enum.find_value(room.positions, fn {position, id} -> if id == user, do: position end)
  end

  # The RoomManager starts each write before it replies; wait for them, then
  # sort by kind, since inserted_at is to the second.
  defp seat_events(user_id) do
    await_tasks()

    Repo.all(from e in SeatEvent, where: e.user_id == ^user_id, select: {e.kind, e.elapsed_ms})
    |> Enum.sort()
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("timed out waiting for condition")

  defp wait_until(fun, attempts) do
    unless fun.() do
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
