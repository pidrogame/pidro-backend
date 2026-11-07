defmodule PidroServer.Games.DisconnectCascadeTest do
  @moduledoc """
  Tests for the three-phase disconnect cascade.

  Phase 1 (Hiccup): Player disconnects → seat becomes :reconnecting → timer scheduled
  Phase 2 (Grace): Hiccup timer fires → bot spawned → seat becomes :bot_substitute
  Phase 3: Grace timer fires → bot keeps covering → seat stays reclaimable

  These tests verify Phase 1 behavior: disconnect triggers :reconnecting state,
  PubSub events are broadcast, reconnect during Phase 1 restores the seat,
  and phase timers are properly scheduled and cancelled.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.{GameAdapter, Lifecycle, RoomManager}
  import PidroServer.RoomManagerCase, only: [expire_phase: 3]

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    # BotSupervisor needed for Phase 2 (SubstituteBot spawning)
    case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
      nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
      _pid -> :ok
    end

    :ok
  end

  # Creates a room with 4 players in :playing state.
  # Returns the room struct and a map of position => user_id.
  defp create_playing_room(user_ids \\ ["user1", "user2", "user3", "user4"]) do
    [host | others] = user_ids
    {:ok, room} = RoomManager.create_room(host, %{name: "Cascade Test"})
    for user_id <- others, do: assert({:ok, _, _} = RoomManager.join_room(room.code, user_id))
    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, playing_room} = RoomManager.get_room(room.code)

    assert playing_room.status == :playing

    # Build position->user_id lookup
    player_positions =
      Enum.reduce(playing_room.seats, %{}, fn {pos, seat}, acc ->
        if seat.user_id, do: Map.put(acc, pos, seat.user_id), else: acc
      end)

    {playing_room, player_positions}
  end

  # Finds the position for a given user_id in the room seats.
  defp position_for(room, user_id) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if seat.user_id == user_id, do: pos
    end)
  end

  describe "explicit live departure" do
    for user_id <- ["user1", "user2"] do
      test "#{user_id} leaves a permanent controller and keeps the room playing" do
        {room, _positions} = create_playing_room()
        user_id = unquote(user_id)
        position = position_for(room, user_id)
        Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

        assert :ok = RoomManager.leave_room(user_id)
        assert {:ok, updated} = RoomManager.get_room(room.code)
        assert updated.status == :playing
        seat = updated.seats[position]
        assert seat.occupant_type == :bot
        assert seat.status == :bot_substitute
        assert Process.alive?(seat.bot_pid)
        assert seat.reserved_for == nil
        refute user_id in Map.values(updated.positions)
        assert {:ok, _game} = GameAdapter.get_state(room.code)
        assert_receive {:bot_substitute_active, %{position: ^position, user_id: ^user_id}}
        assert_receive {:seat_permanently_botted, %{position: ^position}}
      end
    end

    for phase <- [:hiccup, :grace, :permanent] do
      test "leave during #{phase} cancels obsolete timers and retains one controller" do
        {room, _positions} = create_playing_room()
        position = position_for(room, "user2")
        assert :ok = RoomManager.handle_player_disconnect(room.code, "user2")

        if unquote(phase) != :hiccup do
          expire_phase(room.code, position, :phase2_start)
        end

        if unquote(phase) == :permanent do
          expire_phase(room.code, position, :phase3_gone)
        end

        {:ok, before_leave} = RoomManager.get_room(room.code)
        previous_pid = before_leave.seats[position].bot_pid
        assert :ok = RoomManager.leave_room("user2")
        {:ok, after_leave} = RoomManager.get_room(room.code)
        bot_pid = after_leave.seats[position].bot_pid
        assert is_pid(bot_pid) and Process.alive?(bot_pid)
        if previous_pid, do: assert(bot_pid == previous_pid)
        assert after_leave.seats[position].reserved_for == nil
        refute Map.has_key?(after_leave.phase_timers, position)

        stale_ref = before_leave.phase_timers[position] || make_ref()
        send(RoomManager, {:timeout, stale_ref, {:phase2_start, room.code, position}})
        send(RoomManager, {:timeout, stale_ref, {:phase3_gone, room.code, position}})
        RoomManager.handle_player_disconnect(room.code, "user2")
        {:ok, later} = RoomManager.get_room(room.code)
        assert later.seats[position].bot_pid == bot_pid
        assert later.seats[position].status == :bot_substitute
        assert later.phase_timers == %{}
      end
    end

    test "the last human leaving closes the multiplayer game and its bots" do
      {room, _positions} = create_playing_room()

      for user <- ["user2", "user3", "user4"],
          do: assert(:ok = RoomManager.leave_room(user))

      assert {:ok, updated} = RoomManager.get_room(room.code)
      bots = for {_, %{occupant_type: :bot, bot_pid: pid}} <- updated.seats, do: pid
      assert :ok = RoomManager.leave_room("user1")
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
      refute Enum.any?(bots, &Process.alive?/1)
      assert {:error, _} = GameAdapter.get_state(room.code)
    end

    test "a failed bot start preserves membership and its existing timer" do
      {room, _positions} = create_playing_room()
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      {:ok, before_leave} = RoomManager.get_room(room.code)
      supervisor = PidroServer.Games.Bots.BotSupervisor
      original_pid = Process.whereis(supervisor)

      limited_pid =
        start_supervised!({DynamicSupervisor, strategy: :one_for_one, max_children: 0})

      Process.unregister(supervisor)
      Process.register(limited_pid, supervisor)

      try do
        assert {:error, :bot_start_failed} = RoomManager.leave_room("user2")
        assert {:ok, after_leave} = RoomManager.get_room(room.code)
        assert after_leave.positions == before_leave.positions
        assert after_leave.seats == before_leave.seats
        assert after_leave.phase_timers == before_leave.phase_timers
        assert Process.alive?(Process.whereis(RoomManager))
      after
        Process.unregister(supervisor)
        Process.register(original_pid, supervisor)
      end
    end

    test "an owner-opened vacancy stays open when its former occupant leaves" do
      {room, _positions} = create_playing_room()
      position = position_for(room, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      expire_phase(room.code, position, :phase2_start)
      expire_phase(room.code, position, :phase3_gone)
      :ok = RoomManager.leave_room("user2")
      assert {:ok, _} = RoomManager.open_seat(room.code, position, room.host_id)

      assert {:error, :not_in_room} = RoomManager.leave_room("user2")
      assert {:ok, updated} = RoomManager.get_room(room.code)
      assert updated.status == :playing
      assert updated.seats[position].occupant_type == :vacant
      assert updated.seats[position].bot_pid == nil
      assert updated.phase_timers == %{}
    end

    test "an unavailable bot supervisor preserves the room and membership" do
      {room, _positions} = create_playing_room()
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      {:ok, before_leave} = RoomManager.get_room(room.code)
      manager = Process.whereis(RoomManager)
      supervisor = PidroServer.Games.Bots.BotSupervisor
      supervisor_pid = Process.whereis(supervisor)
      Process.unregister(supervisor)

      try do
        assert {:error, :bot_start_failed} = RoomManager.leave_room("user2")
        assert Process.whereis(RoomManager) == manager
        assert {:ok, after_leave} = RoomManager.get_room(room.code)
        assert after_leave.positions == before_leave.positions
        assert after_leave.seats == before_leave.seats
        assert after_leave.phase_timers == before_leave.phase_timers
      after
        Process.register(supervisor_pid, supervisor)
      end
    end

    test "failed phase 2 startup preserves the seat and retries after supervisor recovery" do
      {room, _} = create_playing_room()
      position = position_for(room, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      {:ok, before_start} = RoomManager.get_room(room.code)
      manager = Process.whereis(RoomManager)
      supervisor = PidroServer.Games.Bots.BotSupervisor
      supervisor_pid = Process.whereis(supervisor)
      Process.unregister(supervisor)

      try do
        {:ok, failed} = expire_phase(room.code, position, :phase2_start)
        assert Process.whereis(RoomManager) == manager
        assert failed.seats == before_start.seats
        assert failed.phase_timers[position] != before_start.phase_timers[position]
        assert is_integer(Process.read_timer(failed.phase_timers[position]))
      after
        Process.register(supervisor_pid, supervisor)
      end

      {:ok, recovered} = expire_phase(room.code, position, :phase2_start)
      assert recovered.seats[position].status == :bot_substitute
      assert Process.alive?(recovered.seats[position].bot_pid)
    end

    test "failed close seat preserves the vacancy and allows a later retry" do
      {room, _} = create_playing_room()
      position = position_for(room, "user2")
      :ok = RoomManager.leave_room("user2")
      {:ok, vacant} = RoomManager.open_seat(room.code, position, room.host_id)
      manager = Process.whereis(RoomManager)
      supervisor = PidroServer.Games.Bots.BotSupervisor
      supervisor_pid = Process.whereis(supervisor)
      Process.unregister(supervisor)

      try do
        assert {:error, :bot_start_failed} =
                 RoomManager.close_seat(room.code, position, room.host_id)

        assert Process.whereis(RoomManager) == manager
        {:ok, failed} = RoomManager.get_room(room.code)
        assert failed.seats == vacant.seats
      after
        Process.register(supervisor_pid, supervisor)
      end

      assert {:ok, recovered} = RoomManager.close_seat(room.code, position, room.host_id)
      assert Process.alive?(recovered.seats[position].bot_pid)
    end

    test "a reconnect to a stopped game that is still registered costs only its own table" do
      {room, _positions} = create_playing_room()
      {:ok, other_room} = RoomManager.create_room("other-user")
      manager = Process.whereis(RoomManager)
      position = position_for(room, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      {:ok, game_pid} = PidroServer.Games.GameSupervisor.get_game(room.code)

      # Hold the registry's cleanup so the stopped game stays registered: the
      # window between lookup and call that a reconnect otherwise hits by chance.
      partition = PidroServer.Games.GameRegistry.PIDPartition0
      :sys.suspend(partition)

      try do
        ref = Process.monitor(game_pid)
        Process.exit(game_pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^game_pid, :killed}
        assert {:ok, ^game_pid} = PidroServer.Games.GameSupervisor.get_game(room.code)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:ok, reconnected} = RoomManager.handle_player_reconnect(room.code, "user2")
            assert reconnected.seats[position].status == :connected
          end)

        assert log =~ room.code
        assert Process.whereis(RoomManager) == manager
        assert {:ok, ^other_room} = RoomManager.get_room(other_room.code)
      after
        :sys.resume(partition)
      end
    end

    test "an engine exit during an action does not take down other rooms" do
      {room, positions} = create_playing_room()
      bidding = start_bidding(room.code)
      {:ok, other_room} = RoomManager.create_room("other-user")
      manager = Process.whereis(RoomManager)
      {:ok, game_pid} = PidroServer.Games.GameSupervisor.get_game(room.code)
      :sys.suspend(game_pid)

      try do
        action =
          Task.async(fn ->
            RoomManager.apply_player_action(
              room.code,
              positions[bidding.current_turn],
              bidding.current_turn,
              {:bid, 6}
            )
          end)

        eventually(fn ->
          {:messages, messages} = Process.info(game_pid, :messages)

          Enum.any?(messages, fn
            {:"$gen_call", {^manager, _}, {:apply_action_with_snapshot, _, _, _, _}} -> true
            _ -> false
          end)
        end)

        Process.exit(game_pid, :kill)
        assert {:error, :game_unavailable} = Task.await(action)
        assert Process.whereis(RoomManager) == manager
        assert {:ok, ^other_room} = RoomManager.get_room(other_room.code)
      after
        if Process.alive?(game_pid), do: :sys.resume(game_pid)
      end
    end

    test "a suspended engine releases the manager before the action caller times out" do
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.put(original, :turn_timer_bid_ms, 60_000)
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)

      {room, positions} = create_playing_room()
      bidding = start_bidding(room.code)
      {:ok, game_pid} = PidroServer.Games.GameSupervisor.get_game(room.code)
      :sys.suspend(game_pid)

      try do
        action =
          Task.async(fn ->
            RoomManager.apply_player_action(
              room.code,
              positions[bidding.current_turn],
              bidding.current_turn,
              {:bid, 6}
            )
          end)

        assert {:error, :game_unavailable} = Task.await(action, 1_500)
        assert {:ok, _room} = RoomManager.create_room("unaffected-user")
        assert Process.alive?(game_pid)
      after
        :sys.resume(game_pid)
      end
    end

    test "cleaning the old room preserves a departed user's new membership and channels" do
      {old_room, _} = create_playing_room()
      assert :ok = RoomManager.leave_room("user2")
      assert {:ok, new_room} = RoomManager.create_room("user2", %{})
      assert :ok = RoomManager.register_game_channel(new_room.code, "user2", self())

      assert :ok = RoomManager.close_room(old_room.code)
      assert {:error, :already_in_room} = RoomManager.create_room("user2", %{})

      assert :last_channel_closed =
               RoomManager.unregister_game_channel(new_room.code, "user2", self())

      assert {:ok, room} = RoomManager.get_room(new_room.code)
      assert room.seats.north.user_id == "user2"
    end
  end

  describe "game progression after multiple departures" do
    setup do
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(original,
          hiccup_timeout_ms: 20,
          grace_timeout_ms: 80,
          bot_delay_ms: 1,
          bot_delay_variance_ms: 0,
          bot_min_delay_ms: 1,
          trick_transition_delay_ms: 1,
          hand_transition_delay_ms: 1,
          second_deal_transition_delay_ms: 1,
          turn_timer_bid_ms: 60_000,
          turn_timer_play_ms: 60_000,
          empty_room_ttl_ms: 60_000
        )
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
      :ok
    end

    for {mode, host_first?} <- [
          leave: true,
          leave: false,
          disconnect: true,
          mixed: true,
          mixed: false
        ] do
      test "three #{mode} departures (host first: #{host_first?}) reach the next hand" do
        {room, _positions} = create_playing_room()
        bidding = start_bidding(room.code)

        {human_position, human_id} =
          Enum.find(room.positions, fn {pos, user} ->
            pos != bidding.current_turn and user != room.host_id
          end)

        departing =
          room.positions
          |> Enum.reject(fn {pos, _} -> pos == human_position end)
          |> Enum.sort_by(fn {_, user} ->
            host? = user == room.host_id
            host? != unquote(host_first?)
          end)

        for {position, user_id} <- departing do
          if unquote(mode) == :leave or
               (unquote(mode) == :mixed and position == bidding.current_turn) do
            assert :ok = RoomManager.leave_room(user_id)
          else
            assert :ok = RoomManager.handle_player_disconnect(room.code, user_id)
          end
        end

        # No owner decision is answered and no departed player's turn is driven.
        eventually(fn ->
          {:ok, game} = GameAdapter.get_state(room.code)

          if game.hand_number > bidding.hand_number do
            true
          else
            play_human_turn(room.code, human_id, human_position, game)
            false
          end
        end)

        {:ok, continued} = RoomManager.get_room(room.code)

        assert continued.status == :playing

        host_left? =
          unquote(mode) == :leave or
            (unquote(mode) == :mixed and room.positions[bidding.current_turn] == room.host_id)

        expected_host =
          cond do
            not host_left? -> room.host_id
            unquote(mode) == :mixed and unquote(host_first?) -> room.positions.south
            true -> human_id
          end

        assert continued.host_id == expected_host

        for {position, _} <- departing do
          assert Process.alive?(continued.seats[position].bot_pid)
        end
      end
    end

    test "a bot taking the current bid acts without an external update and retires the human timer" do
      {room, _} = create_playing_room()
      bidding = start_bidding(room.code)
      bidder = bidding.current_turn

      timer =
        eventually(fn ->
          {:ok, current} = RoomManager.get_room(room.code)
          current.turn_timer
        end)

      assert timer.actor_position == bidder

      assert :ok = RoomManager.leave_room(room.positions[bidder])

      eventually(fn ->
        {:ok, game} = GameAdapter.get_state(room.code)
        game.current_turn != bidder
      end)

      assert Process.read_timer(timer.ref) == false
      {:ok, continued} = RoomManager.get_room(room.code)
      assert continued.turn_timer == nil or continued.turn_timer.actor_position != bidder
    end

    test "restart on the current bid schedules one move despite repeated state updates" do
      config = Application.get_env(:pidro_server, Lifecycle, [])
      Application.put_env(:pidro_server, Lifecycle, Keyword.put(config, :bot_delay_ms, 1_000))
      {room, _} = create_playing_room()
      bidding = start_bidding(room.code)
      position = bidding.current_turn
      :ok = RoomManager.leave_room(room.positions[position])
      {:ok, current} = RoomManager.get_room(room.code)
      original = current.seats[position].bot_pid
      Process.exit(original, :kill)

      replacement =
        eventually(fn ->
          {:ok, current} = RoomManager.get_room(room.code)
          pid = current.seats[position].bot_pid
          if is_pid(pid) && pid != original && Process.alive?(pid), do: pid
        end)

      for _ <- 1..20 do
        send(replacement, {:state_update, room.code, bidding})
        send(replacement, {:readiness_updated, %{}})
      end

      assert :sys.get_state(replacement).move_scheduled?

      advanced =
        eventually(fn ->
          {:ok, game} = GameAdapter.get_state(room.code)
          if game.current_turn != position, do: game
        end)

      refute :sys.get_state(replacement).move_scheduled?
      Process.sleep(150)
      assert {:ok, ^advanced} = GameAdapter.get_state(room.code)
      {:ok, current} = RoomManager.get_room(room.code)
      assert current.seats[position].bot_pid == replacement
    end

    test "reclaim after a grace bot's bid preserves its moves and retires the controller" do
      config = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.put(config, :grace_timeout_ms, 60_000)
      )

      {room, _} = create_playing_room()
      bidding = start_bidding(room.code)
      position = bidding.current_turn
      user = room.positions[position]
      :ok = RoomManager.handle_player_disconnect(room.code, user)

      advanced =
        eventually(fn ->
          {:ok, game} = GameAdapter.get_state(room.code)
          if game.current_turn != position, do: game
        end)

      {:ok, grace} = RoomManager.get_room(room.code)
      bot = grace.seats[position].bot_pid
      assert Process.alive?(bot)
      assert grace.seats[position].reserved_for == user
      assert length(advanced.events) > length(bidding.events)
      assert grace.turn_timer == nil or grace.turn_timer.actor_position != position

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user)
      refute Process.alive?(bot)
      assert {:ok, ^advanced} = GameAdapter.get_state(room.code)
    end

    for transition <- [:reclaim, :open] do
      test "recovered temporary bot tolerates shared messages and cannot survive #{transition}" do
        config = Application.get_env(:pidro_server, Lifecycle, [])

        Application.put_env(
          :pidro_server,
          Lifecycle,
          Keyword.merge(config, bot_delay_ms: 1_000, grace_timeout_ms: 60_000)
        )

        {room, _} = create_playing_room()
        start_bidding(room.code)
        position = position_for(room, "user2")
        :ok = RoomManager.handle_player_disconnect(room.code, "user2")
        {:ok, temporary} = expire_phase(room.code, position, :phase2_start)
        original = temporary.seats[position].bot_pid

        for message <- [
              {:readiness_updated, %{}},
              {:seat_lifecycle, %{}},
              {:future_event, %{}},
              {:state_update, room.code, :invalid}
            ] do
          send(original, message)
        end

        assert :sys.get_state(original).room_code == room.code
        Process.exit(original, :kill)

        replacement =
          eventually(fn ->
            {:ok, current} = RoomManager.get_room(room.code)
            pid = current.seats[position].bot_pid
            if is_pid(pid) && pid != original && Process.alive?(pid), do: pid
          end)

        # The shared supervisor has no orphan controller for this seat.
        controllers = DynamicSupervisor.which_children(PidroServer.Games.Bots.BotSupervisor)

        assert Enum.count(controllers, fn {_, pid, _, modules} ->
                 PidroServer.Games.Bots.SubstituteBot in modules &&
                   :sys.get_state(pid).room_code == room.code
               end) == 1

        if unquote(transition) == :reclaim do
          assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, "user2")
        else
          # Only an intentional leave releases the reservation.
          :ok = RoomManager.leave_room("user2")
          {:ok, permanent} = RoomManager.get_room(room.code)
          assert permanent.seats[position].reserved_for == nil
          assert permanent.seats[position].bot_pid == replacement
          assert {:ok, _} = RoomManager.open_seat(room.code, position, room.host_id)
        end

        refute Process.alive?(replacement)
        send(RoomManager, {:DOWN, make_ref(), :process, original, :killed})
        send(RoomManager, {:DOWN, make_ref(), :process, replacement, :shutdown})
        send(RoomManager, :health_check)
        {:ok, current} = RoomManager.get_room(room.code)
        assert current.seats[position].bot_pid == nil

        state = :sys.get_state(RoomManager)

        assert {:reply, {:error, :seat_not_controlled}, ^state} =
                 RoomManager.handle_call(
                   {:apply_substitute_action, room.code, position, :pass, nil},
                   {replacement, make_ref()},
                   state
                 )
      end
    end

    test "mixed game survives readiness traffic and controller crashes through every active phase" do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)
      # A hand has one declaring turn. At this describe's 1 ms bot pace a bot
      # declares before the walk's next look, so give each bot turn the suite's
      # 20 ms; the describe restores the pace on exit.
      config = Application.get_env(:pidro_server, Lifecycle)
      Application.put_env(:pidro_server, Lifecycle, Keyword.merge(config, bot_delay_ms: 20))
      users = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)
      {room, _} = create_playing_room(users)
      start_bidding(room.code)
      human = room.host_id
      human_position = position_for(room, human)

      for user <- users -- [human], do: assert(:ok = RoomManager.leave_room(user))

      assert {:ok, _} = RoomManager.join_spectator_room(room.code, "watcher")
      assert :ok = RoomManager.leave_spectator("watcher")
      assert :ok = RoomManager.handle_player_disconnect(room.code, human)
      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, human)

      # Crash the current controller once in each phase. Human actions go through
      # the same authoritative API as a channel; no bot turn is driven by the test.
      crashed = :ets.new(:crashed_phases, [:set])

      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          eventually(
            fn ->
              {:ok, game} = GameAdapter.get_state(room.code)
              {:ok, current} = RoomManager.get_room(room.code)

              if game.phase == :complete do
                true
              else
                seat = current.seats[game.current_turn]

                if seat && seat.occupant_type == :bot &&
                     :ets.insert_new(crashed, {game.phase}) do
                  old_pid = seat.bot_pid
                  Process.exit(old_pid, :kill)

                  replacement =
                    eventually(fn ->
                      {:ok, recovered} = RoomManager.get_room(room.code)
                      pid = recovered.seats[game.current_turn].bot_pid
                      if is_pid(pid) && pid != old_pid && Process.alive?(pid), do: pid
                    end)

                  send(RoomManager, {:DOWN, make_ref(), :process, old_pid, :killed})
                  send(RoomManager, :health_check)
                  {:ok, recovered} = RoomManager.get_room(room.code)
                  assert recovered.seats[game.current_turn].bot_pid == replacement
                end

                Phoenix.PubSub.broadcast(
                  PidroServer.PubSub,
                  "game:#{room.code}",
                  {:readiness_updated, %{}}
                )

                Phoenix.PubSub.broadcast(
                  PidroServer.PubSub,
                  "game:#{room.code}",
                  {:future_shared_topic_event, %{}}
                )

                play_human_turn(room.code, human, human_position, game)
                false
              end
            end,
            8_000
          )
        end)

      for phase <- [:bidding, :declaring, :playing], do: assert(:ets.member(crashed, phase))
      :ets.delete(crashed)
      assert logs =~ "Recovered substitute bot"
      refute logs =~ "FunctionClauseError"
      refute logs =~ "dead bot_pid"
    end

    # The last to leave sits with bots alone, which abandons nobody.
    test "all humans leaving keeps abandonments without awarding a bot-only result" do
      user_ids = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)
      {room, _} = create_playing_room(user_ids)
      for user_id <- user_ids, do: assert(:ok = RoomManager.leave_room(user_id))

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
      refute Repo.get_by(PidroServer.Stats.GameStats, room_code: room.code)
      assert length(PidroServer.Stats.list_abandonments_for_room(room.code)) == 3
    end
  end

  defp start_bidding(room_code) do
    {:ok, initial} = GameAdapter.get_state(room_code)

    if initial.phase == :dealer_selection,
      do: GameAdapter.apply_action(room_code, :north, :select_dealer)

    eventually(fn ->
      case GameAdapter.get_state(room_code) do
        {:ok, %{phase: :bidding} = game} -> game
        _ -> nil
      end
    end)
  end

  defp play_human_turn(room_code, user_id, position, %{current_turn: position} = game) do
    {:ok, actions} = GameAdapter.get_legal_actions(room_code, position)

    if actions != [] do
      view = Pidro.Core.SeatView.for_seat(game, position)
      {:ok, action, _} = PidroServer.Games.Bots.TimeoutStrategy.pick_action(actions, view)
      resolved = PidroServer.Games.Bots.BotBrain.resolve_action(action, game, position)
      assert {:ok, _} = RoomManager.apply_player_action(room_code, user_id, position, resolved)
    end
  end

  defp play_human_turn(_room_code, _user_id, _position, _game), do: :ok

  defp eventually(fun, attempts \\ 2_000)
  defp eventually(_fun, 0), do: flunk("game did not progress before the deadline")

  defp eventually(fun, attempts) do
    case fun.() do
      result when result in [nil, false] ->
        Process.sleep(5)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  describe "Phase 1 (Hiccup) — disconnect triggers reconnecting" do
    test "disconnect marks seat as :reconnecting with disconnected_at set" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      seat = updated_room.seats[position]

      assert seat.status == :reconnecting
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
      assert seat.disconnected_at != nil
    end

    test "disconnect does not affect other seats" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, updated_room} = RoomManager.get_room(room.code)

      for {pos, seat} <- updated_room.seats, pos != position do
        assert seat.status == :connected,
               "Expected seat at #{pos} to remain :connected, got #{seat.status}"
      end
    end

    test "player_reconnecting event is broadcast on disconnect" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      assert_receive {:player_reconnecting, %{user_id: ^user_id, position: ^position}}, 200
    end

    test "reconnect during Phase 1 restores seat to :connected :human" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      # Verify seat is reconnecting
      {:ok, disconnected_room} = RoomManager.get_room(room.code)
      assert disconnected_room.seats[position].status == :reconnecting

      # Reconnect
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, user_id)
      seat = reconnected_room.seats[position]

      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
      assert seat.disconnected_at == nil
    end

    test "reconnect during Phase 1 broadcasts player_reconnected event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      # Drain the disconnect broadcast
      assert_receive {:player_reconnecting, _}, 200

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)
      assert_receive {:player_reconnected, %{user_id: ^user_id, position: ^position}}, 200
    end

    test "phase transition timer is scheduled on disconnect" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      timer_ref = updated_room.phase_timers[position]

      assert timer_ref != nil
      # Timer should still be active (not yet fired)
      assert is_integer(Process.cancel_timer(timer_ref))
    end

    test "reconnect during Phase 1 cancels the phase timer" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)

      {:ok, disconnected_room} = RoomManager.get_room(room.code)
      timer_ref = disconnected_room.phase_timers[position]
      assert timer_ref != nil

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      {:ok, reconnected_room} = RoomManager.get_room(room.code)
      # Timer should be cleared from phase_timers
      assert reconnected_room.phase_timers[position] == nil
      # Original timer should have been cancelled (returns false if already cancelled)
      assert Process.cancel_timer(timer_ref) == false
    end

    test "a :waiting room disconnect holds the seat without the cascade" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Waiting Room"})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      {:ok, waiting_room} = RoomManager.get_room(room.code)
      assert waiting_room.status == :waiting
      user2_position = position_for(waiting_room, "user2")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      seat = updated_room.seats[user2_position]
      assert seat.status == :reconnecting
      assert seat.occupant_type == :human
      assert %DateTime{} = seat.disconnected_at
      assert updated_room.phase_timers == %{}

      assert_receive {:player_reconnecting, %{user_id: "user2", position: ^user2_position}}, 100

      # The hiccup timeout passes without Phase 2: no bot, the seat stays held.
      Process.sleep(Lifecycle.config(:hiccup_timeout_ms) + 50)

      {:ok, later_room} = RoomManager.get_room(room.code)
      later_seat = later_room.seats[user2_position]
      assert later_seat.status == :reconnecting
      assert later_seat.bot_pid == nil
      assert later_room.phase_timers == %{}
      refute_received {:bot_substitute_active, _}
    end

    test "multiple simultaneous disconnects are independent" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Both seats should be independently :reconnecting
      assert updated_room.seats[user2_position].status == :reconnecting
      assert updated_room.seats[user3_position].status == :reconnecting

      # Both should have independent phase timers
      assert updated_room.phase_timers[user2_position] != nil
      assert updated_room.phase_timers[user3_position] != nil

      assert updated_room.phase_timers[user2_position] !=
               updated_room.phase_timers[user3_position]

      # Should receive two independent PubSub events
      assert_receive {:player_reconnecting, %{user_id: "user2", position: ^user2_position}}, 200
      assert_receive {:player_reconnecting, %{user_id: "user3", position: ^user3_position}}, 200
    end

    test "reconnecting one player does not affect the other's cascade" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Reconnect user2 only
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # user2 should be back to :connected
      assert updated_room.seats[user2_position].status == :connected

      # user3 should still be :reconnecting with active timer
      assert updated_room.seats[user3_position].status == :reconnecting
      assert updated_room.phase_timers[user3_position] != nil

      # user2's timer should be cleaned up
      assert updated_room.phase_timers[user2_position] == nil
    end

    test "disconnecting host triggers cascade (host seat becomes :reconnecting)" do
      {room, _positions} = create_playing_room()
      host_position = position_for(room, "user1")

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      seat = updated_room.seats[host_position]

      assert seat.status == :reconnecting
      assert seat.is_owner == true
      assert seat.user_id == "user1"
    end
  end

  # Helper: disconnect a player and expire its current Phase 2 timer.
  # Returns the updated room after Phase 2 completes.
  defp trigger_phase2(room_code, user_id) do
    {_room, position} = disconnect_and_get_position(room_code, user_id)

    # Manually send the Phase 2 timer message
    expire_phase(room_code, position, :phase2_start)

    # Synchronize: get_room is a GenServer.call, ensuring handle_info processed
    {:ok, updated_room} = RoomManager.get_room(room_code)
    {updated_room, position}
  end

  defp disconnect_and_get_position(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)
    {room, position}
  end

  # Helper: trigger Phase 2 then Phase 3 for a player.
  defp trigger_phase3(room_code, user_id) do
    {_room, position} = trigger_phase2(room_code, user_id)

    # Manually send the Phase 3 timer message
    expire_phase(room_code, position, :phase3_gone)

    {:ok, updated_room} = RoomManager.get_room(room_code)
    {updated_room, position}
  end

  describe "Phase 2 (Grace) — bot spawned after hiccup timeout" do
    test "Phase 2 spawns a bot — seat becomes :bot_substitute with live bot_pid" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {updated_room, position} = trigger_phase2(room.code, user_id)

      seat = updated_room.seats[position]
      assert seat.status == :bot_substitute
      assert seat.occupant_type == :bot
      assert seat.bot_pid != nil
      assert Process.alive?(seat.bot_pid)
      assert seat.reserved_for == user_id
      assert seat.grace_expires_at != nil
      assert seat.user_id == nil
    end

    test "Phase 2 broadcasts bot_substitute_active event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_updated_room, position} = trigger_phase2(room.code, user_id)

      # Drain the disconnect broadcast first
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, %{position: ^position, user_id: ^user_id}}, 200
    end

    test "Phase 2 schedules Phase 3 timer" do
      {room, _positions} = create_playing_room()

      {updated_room, position} = trigger_phase2(room.code, "user2")

      timer_ref = updated_room.phase_timers[position]
      assert timer_ref != nil
      # Timer should still be active (Phase 3 hasn't fired yet)
      assert is_integer(Process.cancel_timer(timer_ref))
    end

    test "reconnect during Phase 2 terminates bot and restores seat" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {phase2_room, position} = trigger_phase2(room.code, user_id)

      # Capture bot pid before reconnect
      bot_pid = phase2_room.seats[position].bot_pid
      assert Process.alive?(bot_pid)

      # Reconnect during Phase 2
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, user_id)

      seat = reconnected_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
      assert seat.bot_pid == nil
      assert seat.reserved_for == nil
      assert seat.grace_expires_at == nil

      # Bot process should be dead
      Process.sleep(50)
      refute Process.alive?(bot_pid)
    end

    test "reconnect during Phase 2 cancels Phase 3 timer" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {phase2_room, position} = trigger_phase2(room.code, user_id)

      timer_ref = phase2_room.phase_timers[position]
      assert timer_ref != nil

      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Timer should be cleared
      assert reconnected_room.phase_timers[position] == nil
      # Original timer should have been cancelled
      assert Process.cancel_timer(timer_ref) == false
    end

    test "reconnect during Phase 2 broadcasts player_reclaimed_seat event" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_phase2_room, position} = trigger_phase2(room.code, user_id)

      # Drain earlier broadcasts
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, _}, 200

      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)
      assert_receive {:player_reclaimed_seat, %{user_id: ^user_id, position: ^position}}, 200
    end

    test "Phase 2 does nothing if player already reconnected (Phase 1)" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      {:ok, disc_room} = RoomManager.get_room(room.code)
      position = position_for(disc_room, user_id)

      # Reconnect during Phase 1
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Now manually send Phase 2 message (timer would have fired)
      send(
        RoomManager,
        {:timeout, disc_room.phase_timers[position], {:phase2_start, room.code, position}}
      )

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Seat should still be :connected (Phase 2 was a no-op)
      seat = updated_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
    end
  end

  describe "grace expiry preserves the player's seat" do
    test "Phase 3 keeps the bot temporary and reserved" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {updated_room, position} = trigger_phase3(room.code, user_id)

      seat = updated_room.seats[position]
      assert seat.status == :bot_substitute
      assert seat.occupant_type == :bot
      assert seat.reserved_for == user_id
      assert seat.bot_pid != nil
      assert Process.alive?(seat.bot_pid)
    end

    test "Phase 3 cleans up phase timer" do
      {room, _positions} = create_playing_room()

      {updated_room, position} = trigger_phase3(room.code, "user2")

      assert updated_room.phase_timers[position] == nil
    end

    test "Phase 3 never broadcasts seat_permanently_botted" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_updated_room, position} = trigger_phase3(room.code, user_id)

      # Drain earlier broadcasts
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, _}, 200
      refute_receive {:seat_permanently_botted, %{position: ^position}}, 20
    end

    test "reconnect after Phase 3 reclaims the seat" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {_updated_room, position} = trigger_phase3(room.code, user_id)

      assert {:ok, returned} = RoomManager.handle_player_reconnect(room.code, user_id)
      assert returned.seats[position].user_id == user_id
    end

    test "reconnect at an expired grace deadline succeeds before Phase 3 runs" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      {phase2_room, position} = trigger_phase2(room.code, user_id)
      seat = phase2_room.seats[position]
      bot_pid = seat.bot_pid

      expired_seat = %{seat | grace_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
      expired_room = %{phase2_room | seats: Map.put(phase2_room.seats, position, expired_seat)}

      :sys.replace_state(RoomManager, fn state ->
        %{state | rooms: Map.put(state.rooms, room.code, expired_room)}
      end)

      assert {:ok, _} =
               RoomManager.handle_player_reconnect(room.code, user_id)

      {:ok, unchanged} = RoomManager.get_room(room.code)
      assert unchanged.seats[position].bot_pid == nil
      assert unchanged.seats[position].user_id == user_id
      assert unchanged.phase_timers[position] == nil
      refute Process.alive?(bot_pid)
    end

    test "Phase 3 does nothing if player already reclaimed (Phase 2)" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      {phase2_room, position} = trigger_phase2(room.code, user_id)

      # Reconnect during Phase 2
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, user_id)

      # Now manually send Phase 3 message (timer would have fired)
      send(
        RoomManager,
        {:timeout, phase2_room.phase_timers[position], {:phase3_gone, room.code, position}}
      )

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Seat should still be :connected (Phase 3 was a no-op)
      seat = updated_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user_id
    end

    test "Phase 3 does not offer the reserved seat to its owner" do
      {room, _positions} = create_playing_room()
      user_id = "user2"

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {_updated_room, position} = trigger_phase3(room.code, user_id)

      # Drain earlier broadcasts
      assert_receive {:player_reconnecting, _}, 200
      assert_receive {:bot_substitute_active, _}, 200
      refute_receive {:seat_permanently_botted, _}, 20

      refute_receive {:owner_decision_available, %{position: ^position, owner_id: "user1"}}, 20
    end
  end

  describe "Multiple disconnects and full lifecycle" do
    for phase <- [:phase2_start, :phase3_gone] do
      test "a queued #{phase} from an earlier disconnect cannot advance a fresh cascade" do
        {room, _} = create_playing_room()
        {disconnected, position} = disconnect_and_get_position(room.code, "user2")

        old_room =
          if unquote(phase) == :phase3_gone do
            {:ok, grace} = expire_phase(room.code, position, :phase2_start)
            grace
          else
            disconnected
          end

        old_ref = old_room.phase_timers[position]
        {:ok, _} = RoomManager.handle_player_reconnect(room.code, "user2")
        assert Process.read_timer(old_ref) == false
        :ok = RoomManager.handle_player_disconnect(room.code, "user2")

        if unquote(phase) == :phase3_gone do
          expire_phase(room.code, position, :phase2_start)
        end

        {:ok, fresh} = RoomManager.get_room(room.code)
        Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
        send(RoomManager, {:timeout, old_ref, {unquote(phase), room.code, position}})
        {:ok, unchanged} = RoomManager.get_room(room.code)
        assert unchanged.seats == fresh.seats
        assert unchanged.phase_timers == fresh.phase_timers
        refute_receive {:bot_substitute_active, _}, 20
        refute_receive {:seat_permanently_botted, _}, 20
      end
    end

    test "real timers preserve one reclaimable bot beyond grace" do
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(original, hiccup_timeout_ms: 100, grace_timeout_ms: 400)
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
      {room, _} = create_playing_room()
      position = position_for(room, "user2")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      assert_receive {:player_reconnecting, %{position: ^position}}, 100
      {:ok, hiccup} = RoomManager.get_room(room.code)
      assert hiccup.seats[position].status == :reconnecting
      assert_receive {:bot_substitute_active, %{position: ^position}}, 500
      {:ok, grace} = RoomManager.get_room(room.code)
      assert grace.seats[position].reserved_for == "user2"
      bot = grace.seats[position].bot_pid
      assert Process.alive?(bot)
      refute_receive {:seat_permanently_botted, %{position: ^position}}, 800
      {:ok, permanent} = RoomManager.get_room(room.code)
      assert permanent.seats[position].bot_pid == bot
      assert permanent.seats[position].reserved_for == "user2"
      assert permanent.phase_timers == %{}
    end

    test "multiple simultaneous disconnects each have independent cascades through Phase 2" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Trigger Phase 2 for both
      expire_phase(room.code, user2_position, :phase2_start)
      expire_phase(room.code, user3_position, :phase2_start)
      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Both should have independent bots
      seat2 = updated_room.seats[user2_position]
      seat3 = updated_room.seats[user3_position]

      assert seat2.status == :bot_substitute
      assert seat3.status == :bot_substitute
      assert seat2.bot_pid != seat3.bot_pid
      assert seat2.reserved_for == "user2"
      assert seat3.reserved_for == "user3"
      assert Process.alive?(seat2.bot_pid)
      assert Process.alive?(seat3.bot_pid)
    end

    test "reclaiming one bot does not affect the other's cascade" do
      {room, _positions} = create_playing_room()
      user2_position = position_for(room, "user2")
      user3_position = position_for(room, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Trigger Phase 2 for both
      expire_phase(room.code, user2_position, :phase2_start)
      expire_phase(room.code, user3_position, :phase2_start)
      {:ok, _} = RoomManager.get_room(room.code)

      # Reclaim user2's seat only
      {:ok, updated_room} = RoomManager.handle_player_reconnect(room.code, "user2")

      # user2 should be back
      assert updated_room.seats[user2_position].status == :connected
      assert updated_room.seats[user2_position].user_id == "user2"

      # user3 should still have bot
      assert updated_room.seats[user3_position].status == :bot_substitute
      assert updated_room.seats[user3_position].reserved_for == "user3"
      assert Process.alive?(updated_room.seats[user3_position].bot_pid)
    end

    test "game end cancels pending phases and stops bots without losing grace reservations" do
      {room, _} = create_playing_room()
      {grace, grace_pos} = trigger_phase2(room.code, "user2")
      bot = grace.seats[grace_pos].bot_pid
      {hiccup, hiccup_pos} = disconnect_and_get_position(room.code, "user3")
      refs = hiccup.phase_timers

      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 40}})
      {:ok, finished} = RoomManager.get_room(room.code)
      assert finished.status == :finished
      assert finished.phase_timers == %{}
      assert finished.turn_timer == nil
      refute Process.alive?(bot)
      assert finished.seats[grace_pos].bot_pid == nil
      assert finished.seats[grace_pos].reserved_for == "user2"
      for {_, ref} <- refs, do: assert(Process.read_timer(ref) == false)

      send(RoomManager, {:timeout, refs[hiccup_pos], {:phase2_start, room.code, hiccup_pos}})
      send(RoomManager, {:timeout, refs[grace_pos], {:phase3_gone, room.code, grace_pos}})
      {:ok, unchanged} = RoomManager.get_room(room.code)
      assert unchanged.seats == finished.seats
      {:ok, returned} = RoomManager.handle_player_reconnect(room.code, "user2")
      assert returned.seats[grace_pos].status == :connected
      assert returned.turn_timer == nil
    end

    test "full lifecycle: disconnect → Phase 2 → Phase 3 → successful reconnect" do
      {room, _positions} = create_playing_room()
      user_id = "user2"
      position = position_for(room, user_id)

      # Phase 1: Disconnect
      :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      {:ok, room1} = RoomManager.get_room(room.code)
      assert room1.seats[position].status == :reconnecting

      # Phase 2: Bot spawns
      expire_phase(room.code, position, :phase2_start)
      {:ok, room2} = RoomManager.get_room(room.code)
      assert room2.seats[position].status == :bot_substitute
      assert room2.seats[position].reserved_for == user_id

      # Phase 3: Still reserved
      expire_phase(room.code, position, :phase3_gone)
      {:ok, room3} = RoomManager.get_room(room.code)
      assert room3.seats[position].status == :bot_substitute
      assert room3.seats[position].reserved_for == user_id

      assert {:ok, returned} =
               RoomManager.handle_player_reconnect(room.code, user_id)

      assert returned.seats[position].user_id == user_id
    end
  end
end
