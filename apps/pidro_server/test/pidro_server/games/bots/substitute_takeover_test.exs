defmodule PidroServer.Games.Bots.SubstituteTakeoverTest do
  @moduledoc """
  Real rooms where the rulebook bot takes over or fills seats and plays on.
  """

  use PidroServer.DataCase, async: false

  import ExUnit.CaptureLog
  import PidroServer.RoomManagerCase, only: [expire_phase: 3]

  alias Pidro.Bot.Rulebook
  alias Pidro.Core.SeatView
  alias PidroServer.Games.Bots.{BotBrain, BotManager, BotSupervisor}
  alias PidroServer.Games.Bots.Strategies.RulebookStrategy
  alias PidroServer.Games.{GameAdapter, Lifecycle, RoomManager}

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    for supervisor <- [BotSupervisor, BotManager] do
      if GenServer.whereis(supervisor) == nil, do: start_supervised!(supervisor)
    end

    # Only the test drives human seats; their turn timers must not fire.
    original = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.merge(original, turn_timer_bid_ms: 60_000, turn_timer_play_ms: 60_000)
    )

    on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
    :ok
  end

  defp playing_room(config \\ %{}) do
    [host | others] = users = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)
    {:ok, room} = RoomManager.create_room(host, Map.merge(%{name: "Takeover"}, config))
    for user <- others, do: {:ok, _, _} = RoomManager.join_room(room.code, user)
    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, room} = RoomManager.get_room(room.code)

    {:ok, game} = GameAdapter.get_state(room.code)

    if game.phase == :dealer_selection,
      do: {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)

    game = eventually(fn -> match_phase(room.code, :bidding) end)
    {room, Map.new(room.positions), users, game}
  end

  defp match_phase(room_code, phase) do
    case GameAdapter.get_state(room_code) do
      {:ok, %{phase: ^phase} = game} -> game
      _ -> nil
    end
  end

  # A human seat plays what the rulebook would, through the human action path.
  defp human_move(room_code, positions, game) do
    position = game.current_turn
    {:ok, legal} = GameAdapter.get_legal_actions(room_code, position)
    {action, _reason} = Rulebook.decide(SeatView.for_seat(game, position), legal)

    assert {:ok, _} =
             RoomManager.apply_player_action(room_code, positions[position], position, action)
  end

  defp eventually(fun, attempts \\ 2_000)
  defp eventually(_fun, 0), do: flunk("the game did not progress before the deadline")

  defp eventually(fun, attempts) do
    case fun.() do
      result when result in [nil, false] ->
        Process.sleep(5)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp collect_reasons(position, acc \\ []) do
    receive do
      {:bot_reasoning, _code, %{position: ^position, reason: reason}} ->
        collect_reasons(position, [reason | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp trumps_left(game, position),
    do: Enum.count(game.players[position].hand, &Pidro.Core.Card.is_trump?(&1, game.trump_suit))

  # Bid 10 from the first seat, everyone else passes, then play two tricks.
  # Retries with a fresh room in the rare deal where the bidder has no trump
  # left for the substitute to play.
  defp bidder_after_two_tricks(attempts \\ 5) do
    {room, positions, _users, game} = playing_room()
    bidder = game.current_turn

    assert {:ok, _} =
             RoomManager.apply_player_action(room.code, positions[bidder], bidder, {:bid, 10})

    for _ <- 1..3 do
      {:ok, game} = GameAdapter.get_state(room.code)
      pos = game.current_turn
      assert {:ok, _} = RoomManager.apply_player_action(room.code, positions[pos], pos, :pass)
    end

    declaring = eventually(fn -> match_phase(room.code, :declaring) end)
    human_move(room.code, positions, declaring)

    game =
      eventually(fn ->
        {:ok, game} = GameAdapter.get_state(room.code)

        cond do
          game.phase == :playing and length(game.tricks) == 2 and game.current_trick == nil ->
            game

          game.phase == :playing and game.current_turn ->
            human_move(room.code, positions, game) && nil

          true ->
            nil
        end
      end)

    cond do
      trumps_left(game, bidder) > 0 -> {room, positions, bidder, game}
      attempts > 1 -> bidder_after_two_tricks(attempts - 1)
      true -> flunk("no deal left the bidder a trump after two tricks")
    end
  end

  test "a substitute for a disconnected seat plays the rulebook" do
    {room, positions, _users, _game} = playing_room()
    :ok = RoomManager.handle_player_disconnect(room.code, positions[:east])
    {:ok, room} = expire_phase(room.code, :east, :phase2_start)

    pid = room.seats[:east].bot_pid
    assert is_pid(pid)
    assert :sys.get_state(pid).strategy == RulebookStrategy
  end

  for {difficulty, strategy} <- [
        random: RulebookStrategy,
        basic: RulebookStrategy,
        smart: RulebookStrategy
      ] do
    test "#{difficulty} reaches substitutes and survives their recovery" do
      {room, positions, _users, _game} = playing_room(%{bot_difficulty: unquote(difficulty)})
      :ok = RoomManager.handle_player_disconnect(room.code, positions[:east])
      {:ok, room} = expire_phase(room.code, :east, :phase2_start)
      pid = room.seats.east.bot_pid
      assert :sys.get_state(pid).strategy == unquote(strategy)
      Process.exit(pid, :kill)

      recovered =
        eventually(fn ->
          {:ok, current} = RoomManager.get_room(room.code)
          next = current.seats.east.bot_pid
          if is_pid(next) and next != pid and Process.alive?(next), do: next
        end)

      assert :sys.get_state(recovered).strategy == unquote(strategy)
    end
  end

  test "AE14: a human bids 10, plays two tricks and drops; the substitute finishes the hand" do
    log =
      capture_log(fn ->
        {room, positions, bidder, at_drop} = bidder_after_two_tricks()
        events_at_drop = length(at_drop.events)

        Phoenix.PubSub.subscribe(PidroServer.PubSub, BotBrain.reasoning_topic(room.code))
        :ok = RoomManager.handle_player_disconnect(room.code, positions[bidder])
        {:ok, _} = expire_phase(room.code, bidder, :phase2_start)

        finished =
          eventually(fn ->
            {:ok, game} = GameAdapter.get_state(room.code)

            cond do
              game.hand_number > at_drop.hand_number or game.phase == :complete ->
                game

              game.phase == :playing and game.current_turn not in [nil, bidder] ->
                human_move(room.code, positions, game) && nil

              true ->
                nil
            end
          end)

        after_drop = Enum.drop(finished.events, events_at_drop)
        assert Enum.any?(after_drop, &match?({:card_played, ^bidder, _}, &1))

        team = Pidro.Core.Types.position_to_team(bidder)
        assert Enum.any?(after_drop, &match?({:hand_scored, ^team, _}, &1))

        # Every substitute move came from a rule, not the fallback. A hand is
        # settled when the bidder leads with every other seat cold; the room
        # lays those cards down (PID-366), so they carry no reasoning.
        reasons = collect_reasons(bidder)

        cold =
          for {position, player} <- at_drop.players,
              position == bidder or player.eliminated?,
              into: MapSet.new(),
              do: position

        on_table = if at_drop.current_trick, do: length(at_drop.current_trick.plays), else: 0

        {plays, _cold, _on_table} =
          Enum.reduce(after_drop, {0, cold, on_table}, fn
            {:player_went_cold, position, _cards}, {plays, cold, on_table} ->
              {plays, MapSet.put(cold, position), on_table}

            {:trick_won, _position, _points}, {plays, cold, _on_table} ->
              {plays, cold, 0}

            {:card_played, ^bidder, _card}, {plays, cold, on_table} ->
              swept? = on_table == 0 and MapSet.size(cold) == 4
              {if(swept?, do: plays, else: plays + 1), cold, on_table + 1}

            {:card_played, _position, _card}, {plays, cold, on_table} ->
              {plays, cold, on_table + 1}

            _event, acc ->
              acc
          end)

        assert length(reasons) == plays

        for reason <- reasons,
            do: refute(reason =~ ~r/No rule applied|failed|recognise|not allowed/, reason)
      end)

    refute log =~ "action failed"
    refute log =~ "raised"
    refute log =~ "not legal"
  end

  describe "the deal hold" do
    @hold_ms 300

    # As in production, the cut is shown for longer than a bot's move takes,
    # so no move the bots scheduled during the cut is still pending at the deal.
    setup do
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(original,
          dealer_selection_delay_ms: 100,
          deal_transition_delay_ms: @hold_ms,
          hand_transition_delay_ms: 1
        )
      )

      :ok
    end

    test "bots in every other seat bid only once each hand's deal has been shown" do
      host = Ecto.UUID.generate()
      {:ok, room} = RoomManager.create_room(host, %{name: "Deal hold"})

      for position <- [:east, :south, :west],
          do: {:ok, _} = BotManager.start_bot(room.code, position, :basic, 1)

      :ok = GameAdapter.subscribe(room.code)
      PidroServer.RoomFixtures.ready_room(room.code)
      {:ok, room} = RoomManager.get_room(room.code)
      GameAdapter.apply_action(room.code, :north, :select_dealer)

      hands = watch_hands(room.code, Map.new(room.positions), %{})

      for {hand, dealt_delay} <- [{1, @hold_ms}, {2, 1 + @hold_ms}] do
        %{dealt_at: dealt_at, bids: bids, delays: [delay | later], settled: settled} =
          Map.fetch!(hands, hand)

        # A hand that ended settled also holds its lay-down (PID-366).
        dealt_delay =
          dealt_delay + if settled, do: Lifecycle.config(:settle_presentation_ms), else: 0

        bot_bids = for {position, at} <- bids, position != :north, do: at - dealt_at

        assert length(bot_bids) >= 3
        assert Enum.all?(bot_bids, &(&1 >= @hold_ms)), inspect(bot_bids)

        # Only the broadcast that deals the hand carries the hold.
        assert delay == dealt_delay
        assert Enum.all?(later, &(&1 < @hold_ms))
      end

      BotManager.stop_all_bots(room.code)
    end
  end

  # Follows the game topic until the third hand is dealt, recording per hand
  # when it was dealt, each bid (server clock) and the broadcast delays.
  defp watch_hands(code, positions, hands) do
    receive do
      {:state_update, ^code, %{state: game, server_time_ms: at} = payload} ->
        hands = record(hands, game, at, payload.transition_delay_ms)

        if Map.has_key?(hands, 3) or game.phase == :complete,
          do: hands,
          else: watch_hands(code, positions, hands)

      _other ->
        watch_hands(code, positions, hands)
    after
      5 ->
        drive_human(code, positions, hands)
        watch_hands(code, positions, hands)
    end
  end

  defp record(hands, %{phase: :bidding, hand_number: hand} = game, at, delay)
       when not is_map_key(hands, hand) do
    settled = match?(%{last_hand: %{settled: %{}}}, game)
    entry = %{dealt_at: at, bids: [], delays: [], settled: settled}
    record(Map.put(hands, hand, entry), game, at, delay)
  end

  defp record(hands, %{hand_number: hand} = game, at, delay) when is_map_key(hands, hand) do
    Map.update!(hands, hand, fn entry ->
      new_bids = for bid <- Enum.drop(game.bids, length(entry.bids)), do: {bid.position, at}
      %{entry | bids: entry.bids ++ new_bids, delays: entry.delays ++ [delay]}
    end)
  end

  defp record(hands, _game, _at, _delay), do: hands

  defp drive_human(code, positions, hands) do
    {:ok, game} = GameAdapter.get_state(code)

    if human_turn?(game, hands) do
      {:ok, legal} = GameAdapter.get_legal_actions(code, :north)
      {action, _reason} = Rulebook.decide(SeatView.for_seat(game, :north), legal)
      action = BotBrain.resolve_action(action, game, :north)
      RoomManager.apply_player_action(code, positions[:north], :north, action)
    end
  end

  # Like the app, the human bids only once the deal has been shown.
  # A synchronous state read can overtake consumption of the deal broadcast.
  defp human_turn?(%{current_turn: :north, phase: :bidding, hand_number: hand}, hands)
       when is_map_key(hands, hand),
       do: System.system_time(:millisecond) - hands[hand].dealt_at >= @hold_ms

  defp human_turn?(%{current_turn: :north, phase: phase}, _hands),
    do: phase in [:declaring, :second_deal, :playing]

  defp human_turn?(_game, _hands), do: false

  test "leaving a table of rulebook bots stops it instead of playing for nobody" do
    host = Ecto.UUID.generate()
    {:ok, room} = RoomManager.create_room(host, %{name: "All bots"})

    log =
      capture_log(fn ->
        {:ok, _pids} = BotManager.start_bots(room.code, 3, :basic, 0)
        PidroServer.RoomFixtures.ready_room(room.code)
        assert :ok = RoomManager.leave_room(host)

        assert {:error, :room_not_found} = RoomManager.get_room(room.code)
        assert {:error, _} = GameAdapter.get_state(room.code)
      end)

    # Every seat-filler may try to cut for dealer at once. Only the first cut
    # counts; the others fail as invalid or, once bidding has begun, as not
    # their turn. Any other failed action is a real failure.
    failures =
      log
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ "action failed"))
      |> Enum.reject(&String.ends_with?(&1, "(:select_dealer)"))

    assert failures == []
    refute log =~ "raised"
    BotManager.stop_all_bots(room.code)
  end
end
