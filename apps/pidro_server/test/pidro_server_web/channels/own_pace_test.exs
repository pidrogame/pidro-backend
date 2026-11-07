defmodule PidroServerWeb.OwnPaceTest do
  use PidroServerWeb.ChannelCase, async: false

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.{GameAdapter, Lifecycle, RoomManager}
  alias PidroServer.Games.Bots.{BotBrain, BotManager}
  alias PidroServer.RoomFixtures
  alias PidroServerWeb.GameChannel

  setup do
    Process.flag(:trap_exit, true)
    RoomManager.reset_for_test()
    previous = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.merge(previous,
        own_bot_delay_ms: 5,
        own_trick_transition_delay_ms: 5,
        bot_delay_variance_ms: 0,
        second_deal_transition_delay_ms: 5,
        deal_transition_delay_ms: 5
      )
    )

    on_exit(fn ->
      PidroServer.RoomManagerCase.cleanup()
      Application.put_env(:pidro_server, Lifecycle, previous)
    end)

    :ok
  end

  test "return after the absence deadline before the sweep uses the existing closed-room error" do
    {room, user, _socket} = solo_table(:finnish)
    RoomFixtures.ready_room(room.code)
    :ok = RoomManager.handle_player_disconnect(room.code, user.id)

    :sys.replace_state(RoomManager, fn state ->
      put_in(
        state.rooms[room.code].seats.north.disconnected_at,
        DateTime.add(DateTime.utc_now(), -30 * 60, :second)
      )
    end)

    {:ok, fresh} = create_socket(user)

    assert {:error, %{reason: "room not found", error_code: "room_not_found"}} =
             subscribe_and_join(fresh, GameChannel, "game:#{room.code}")

    assert {:error, :room_not_found} = RoomManager.get_room(room.code)
  end

  for variant <- [:finnish, :louisiana] do
    @tag timeout: 90_000
    test "#{variant}: real bots wait after a hand, reconnect keeps it, Continue deals once" do
      {room, user, socket} = solo_table(unquote(variant))
      ref = push(socket, "set_pace", %{"pace" => "own"})
      assert_reply ref, :ok, %{pace: "own"}
      RoomFixtures.ready_room(room.code)

      held = play_hand(room.code, socket, System.monotonic_time(:millisecond) + 10_000)
      assert held.phase == :hand_complete
      assert held.hand_number == 1
      assert held.last_hand.hand_number == 1
      assert_push "game_state", %{state: %{pace: "own", awaiting_continue: true}}
      assert {:ok, nil} = RoomManager.get_turn_timer(room.code)

      # No hand timer is installed. Exercise the real wait as well as aged cleanup.
      wait_ms = if unquote(variant) == :finnish, do: 60_000, else: 200
      Process.sleep(wait_ms)
      assert {:ok, ^held} = GameAdapter.get_state(room.code)
      :ok = RoomManager.handle_player_disconnect(room.code, user.id)
      old = DateTime.add(DateTime.utc_now(), -31 * 60, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old)
      send(RoomManager, :cleanup_abandoned_rooms)
      send(RoomManager, :health_check)
      assert {:ok, paused} = RoomManager.get_room(room.code)
      assert paused.seats.north.occupant_type == :human
      assert paused.phase_timers == %{}
      assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user.id)

      {:ok, fresh} = create_socket(user)
      {:ok, reply, reconnected} = subscribe_and_join(fresh, GameChannel, "game:#{room.code}")
      assert reply.state.pace == "own"
      assert reply.state.awaiting_continue
      assert reply.state.hand_number == 1

      ref = push(reconnected, "continue_hand", %{})
      assert_reply ref, :ok
      assert_push "game_state", %{state: %{hand_number: 2, awaiting_continue: false}}
      {:ok, dealt} = GameAdapter.get_state(room.code)
      assert dealt.hand_number == 2
      assert Enum.all?(dealt.players, fn {_, player} -> length(player.hand) == 9 end)
      ref = push(reconnected, "continue_hand", %{})
      assert_reply ref, :ok
      assert {:ok, %{hand_number: 2}} = GameAdapter.get_state(room.code)
    end
  end

  test "a human's lone trumps are not settled and an existing turn timer cannot take over" do
    {room, user, socket} = solo_table(:finnish, false, 5_000)
    RoomFixtures.ready_room(room.code)
    {:ok, pid} = GameAdapter.get_game(room.code)
    base = Pidro.Core.GameState.new(seed: 1)

    bidding = %{base | phase: :bidding, current_turn: :north, current_dealer: :west}
    :ok = GenServer.call(pid, {:set_state, bidding})
    {:ok, :ok} = GameAdapter.set_pace(room.code, :quick)
    timer = wait_for_timer(room.code, 100)

    ref = push(socket, "set_pace", %{"pace" => "own"})
    assert_reply ref, :ok, %{pace: "own"}
    assert {:ok, nil} = RoomManager.get_turn_timer(room.code)
    assert {:ok, %{config: %{pace: :own}}} = GameAdapter.get_state(room.code)

    for _ <- 1..4 do
      send(RoomManager, {:turn_timer_expired, room.code, timer.timer_id, timer.key})
    end

    players =
      Map.new(base.players, fn {position, player} ->
        hand = if position == :north, do: [{14, :hearts}, {10, :hearts}, {2, :hearts}], else: []
        {position, %{player | hand: hand, eliminated?: position != :north}}
      end)

    settled = %{
      base
      | phase: :playing,
        current_turn: :north,
        current_dealer: :west,
        trump_suit: :hearts,
        highest_bid: {:north, 6},
        bidding_team: :north_south,
        players: players,
        config: Map.put(base.config, :pace, :own)
    }

    :ok = GenServer.call(pid, {:set_state, settled})
    assert {:north, _} = Pidro.Game.Play.settled_play(settled)
    assert BotBrain.should_make_move?(settled, :north)
    send(RoomManager, {:settle_hand, room.code, length(settled.events), 3})
    Process.sleep(150)
    assert {:ok, ^settled} = GameAdapter.get_state(room.code)
    assert {:ok, current} = RoomManager.get_room(room.code)
    assert current.seats.north.user_id == user.id
    assert current.seats.north.occupant_type == :human
    assert current.consecutive_timeouts == %{}

    ref = push(socket, "play_card", %{"card" => %{"rank" => 10, "suit" => "hearts"}})
    assert_reply ref, :ok
    assert_push "game_state", %{transition_delay_ms: 5}
    Process.sleep(150)
    assert {:ok, after_play} = GameAdapter.get_state(room.code)
    assert after_play.players.north.hand == [{14, :hearts}, {2, :hearts}]
    assert Enum.any?(after_play.events, &(&1 == {:card_played, :north, {10, :hearts}}))
  end

  test "two humans and spectators cannot set pace; a second human restores Quick" do
    {room, user, socket} = solo_table(:finnish, false)
    ref = push(socket, "set_pace", %{"pace" => "own"})
    assert_reply ref, :ok, %{pace: "own"}
    RoomFixtures.ready_room(room.code)
    held = play_hand(room.code, socket, System.monotonic_time(:millisecond) + 10_000)

    other = AccountsFixtures.user_fixture()
    {:ok, _} = RoomManager.join_spectator_room(room.code, other.id)
    {:ok, fresh} = create_socket(other)
    {:ok, _, spectator} = subscribe_and_join(fresh, GameChannel, "game:#{room.code}")
    ref = push(spectator, "set_pace", %{"pace" => "own"})
    assert_reply ref, :error, %{reason: "not_solo"}
    ref = push(spectator, "continue_hand", %{})
    assert_reply ref, :ok
    assert {:ok, ^held} = GameAdapter.get_state(room.code)

    {:ok, seated} = RoomManager.get_room(room.code)
    :ok = RoomManager.leave_room(seated.positions.east)
    {:ok, _} = RoomManager.open_seat(room.code, :east, user.id)
    assert {:ok, joined, :east} = RoomManager.join_as_substitute(room.code, other.id)
    assert joined.pace == :quick
    assert {:ok, %{hand_number: 2, config: %{pace: :quick}}} = GameAdapter.get_state(room.code)
    ref = push(socket, "set_pace", %{"pace" => "own"})
    assert_reply ref, :error, %{reason: "not_solo"}
    ref = push(socket, "set_pace", %{"pace" => "invalid"})
    assert_reply ref, :error, %{reason: "invalid_pace"}
  end

  test "rematch keeps pace and choosing Quick releases a held hand" do
    {room, user, socket} = solo_table(:finnish)
    ref = push(socket, "set_pace", %{"pace" => "own"})
    assert_reply ref, :ok
    RoomFixtures.ready_room(room.code)
    play_hand(room.code, socket, System.monotonic_time(:millisecond) + 10_000)

    ref = push(socket, "set_pace", %{"pace" => "quick"})
    assert_reply ref, :ok, %{pace: "quick"}
    assert {:ok, %{hand_number: 2, config: %{pace: :quick}}} = GameAdapter.get_state(room.code)
    ref = push(socket, "set_pace", %{"pace" => "own"})
    assert_reply ref, :ok

    send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 20}})
    {:ok, readiness} = RoomManager.readiness(room.code)

    for pace <- ["quick", "own"] do
      ref = push(socket, "set_pace", %{"pace" => pace})
      assert_reply ref, :ok, %{pace: ^pace}
      assert_push "game_state", %{state: %{pace: ^pace}}
      {:ok, updated} = GameAdapter.get_state(room.code)
      assert Atom.to_string(updated.config.pace) == pace
    end

    assert {:ok, _} =
             RoomManager.confirm_rematch(
               room.code,
               room.id,
               user.id,
               self(),
               readiness.ready_epoch
             )

    assert {:ok, %{game_number: 2, pace: :own}} = RoomManager.get_room(room.code)
    assert {:ok, %{config: %{pace: :own}}} = GameAdapter.get_state(room.code)
  end

  test "admitting a second human does not crash the room manager if the game stopped" do
    {room, user, socket} = solo_table(:finnish, false, 5_000)
    ref = push(socket, "set_pace", %{"pace" => "own"})
    assert_reply ref, :ok
    seated = RoomFixtures.ready_room(room.code)
    :ok = RoomManager.leave_room(seated.positions.east)
    {:ok, _} = RoomManager.open_seat(room.code, :east, user.id)
    :ok = PidroServer.Games.GameSupervisor.stop_game(room.code)
    other = AccountsFixtures.user_fixture()
    assert {:ok, %{pace: :quick}, :east} = RoomManager.join_as_substitute(room.code, other.id)
    assert {:ok, %{pace: :quick}} = RoomManager.get_room(room.code)
  end

  defp solo_table(variant, solo \\ true, delay \\ nil) do
    user = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(user.id, %{solo: solo, rule_set: variant})

    for position <- [:east, :south, :west] do
      {:ok, _} = BotManager.start_bot(room.code, position, :basic, delay)
    end

    {:ok, socket} = create_socket(user)
    {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")
    {room, user, socket}
  end

  defp wait_for_timer(code, attempts) when attempts > 0 do
    {:ok, room} = RoomManager.get_room(code)

    if room.turn_timer do
      room.turn_timer
    else
      Process.sleep(1)
      wait_for_timer(code, attempts - 1)
    end
  end

  defp play_hand(code, socket, deadline) do
    assert System.monotonic_time(:millisecond) < deadline, "hand did not finish"
    {:ok, state} = GameAdapter.get_state(code)

    if state.phase == :hand_complete do
      state
    else
      {:ok, actions} = GameAdapter.get_legal_actions(code, :north)

      if state.phase != :dealer_selection and actions != [] do
        view = Pidro.Core.SeatView.for_seat(state, :north)
        {action, _reason} = Pidro.Bot.Rulebook.decide(view, actions)
        action = BotBrain.resolve_action(action, state, :north)
        {event, params} = wire_action(action)
        ref = push(socket, event, params)
        assert_reply ref, :ok
      end

      Process.sleep(2)
      play_hand(code, socket, deadline)
    end
  end

  defp wire_action(:pass), do: {"bid", %{"amount" => "pass"}}
  defp wire_action({:bid, amount}), do: {"bid", %{"amount" => amount}}

  defp wire_action({:declare_trump, suit}),
    do: {"declare_trump", %{"suit" => Atom.to_string(suit)}}

  defp wire_action({:play_card, card}), do: {"play_card", %{"card" => wire_card(card)}}

  defp wire_action({:select_hand, cards}),
    do: {"select_hand", %{"cards" => Enum.map(cards, &wire_card/1)}}

  defp wire_card({rank, suit}), do: %{"rank" => rank, "suit" => Atom.to_string(suit)}
end
