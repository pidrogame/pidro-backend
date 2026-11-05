defmodule PidroServer.Games.TableCleanupTest do
  use PidroServer.ArchiveCase, async: false

  alias PidroServer.{AccountsFixtures, RoomFixtures, RoomManagerCase}
  alias PidroServer.Games.{GameAdapter, GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Stats.AbandonmentEvent

  setup do
    original = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(:pidro_server, Lifecycle,
      hiccup_timeout_ms: 60_000,
      grace_timeout_ms: 120_000,
      turn_timer_bid_ms: 600_000,
      turn_timer_play_ms: 600_000,
      dealer_selection_delay_ms: 600_000
    )

    on_exit(fn ->
      RoomManagerCase.cleanup()
      Application.put_env(:pidro_server, Lifecycle, original)
    end)

    :ok
  end

  for solo <- [true, false], pace <- [:quick, :own] do
    test "one human against bots (solo=#{solo}, pace=#{pace}) waits 29 minutes and closes at 30 without rewards" do
      {room, user} = bot_table(unquote(solo), unquote(pace))
      {:ok, game} = GameSupervisor.get_game(room.code)
      bots = Enum.map([:east, :south, :west], &room.seats[&1].bot_pid)
      :ok = RoomManager.handle_player_disconnect(room.code, user.id)
      {:ok, away} = RoomManager.get_room(room.code)
      assert away.seats.north.status == :reconnecting
      assert away.phase_timers == %{}

      age_absence(room.code, 29)
      sweep()
      assert {:ok, waiting} = RoomManager.get_room(room.code)
      assert waiting.seats.north.occupant_type == :human
      assert waiting.seats.north.bot_pid == nil
      assert Repo.aggregate(AbandonmentEvent, :count) == 0

      age_absence(room.code, 30)
      sweep()
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
      assert {:error, :room_not_found} = RoomManager.handle_player_reconnect(room.code, user.id)
      refute Process.alive?(game)
      refute Enum.any?(bots, &Process.alive?/1)
      assert Repo.aggregate("game_stats", :count) == 0
      assert Repo.aggregate("game_xp", :count) == 0
      assert Repo.aggregate(AbandonmentEvent, :count) == 0
    end
  end

  test "return at 29 minutes resumes the same game and cancels expiry" do
    {room, user} = bot_table(false, :quick)
    {:ok, before} = GameAdapter.get_snapshot(room.code)
    :ok = RoomManager.handle_player_disconnect(room.code, user.id)
    age_absence(room.code, 29)
    assert {:ok, _} = RoomManager.handle_player_reconnect(room.code, user.id)
    sweep()
    assert {:ok, resumed} = GameAdapter.get_snapshot(room.code)
    assert Map.delete(resumed, :server_time_ms) == Map.delete(before, :server_time_ms)

    assert {:ok, %{seats: %{north: %{status: :connected, disconnected_at: nil}}}} =
             RoomManager.get_room(room.code)
  end

  test "expiring an old bot table preserves membership in the player's new table" do
    {old, user} = bot_table(false, :quick)
    :ok = RoomManager.handle_player_disconnect(old.code, user.id)
    age_absence(old.code, 30)
    {:ok, current} = RoomManager.create_room(user.id)
    sweep()
    assert {:error, :room_not_found} = RoomManager.get_room(old.code)
    assert :ok = RoomManager.leave_room(user.id)
    assert {:error, :room_not_found} = RoomManager.get_room(current.code)
  end

  test "closing a table removes mappings for earlier occupants too" do
    users = for _ <- 1..4, do: AccountsFixtures.user_fixture()
    [host, departed | others] = users
    {:ok, room} = RoomManager.create_room(host.id)
    for user <- [departed | others], do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
    RoomFixtures.ready_room(room.code)
    :ok = RoomManager.handle_player_disconnect(room.code, departed.id)
    {:ok, _} = RoomManagerCase.expire_phase(room.code, :east, :phase2_start)
    :ok = RoomManager.leave_room(departed.id)
    {:ok, _} = RoomManager.open_seat(room.code, :east, host.id)
    replacement = AccountsFixtures.user_fixture()
    {:ok, _, :east} = RoomManager.join_as_substitute(room.code, replacement.id)
    for user <- others ++ [replacement, host], do: :ok = RoomManager.leave_room(user.id)
    assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    assert {:error, :not_in_room} = RoomManager.leave_room(departed.id)
  end

  test "a settled bot hand resumes its automatic sweep after the human returns" do
    {room, user} = bot_table(true, :quick)
    {:ok, pid} = GameSupervisor.get_game(room.code)
    base = Pidro.Core.GameState.new(seed: 1)

    players =
      Map.new(base.players, fn {position, player} ->
        hand = if position == :south, do: [{14, :hearts}, {10, :hearts}], else: []
        {position, %{player | hand: hand, eliminated?: position != :south}}
      end)

    settled = %{
      base
      | phase: :playing,
        players: players,
        trump_suit: :hearts,
        current_turn: :south,
        current_dealer: :west,
        highest_bid: {:south, 6},
        bidding_team: :north_south,
        current_trick: %Pidro.Core.Types.Trick{number: 1, leader: :south},
        trick_number: 1
    }

    :ok = RoomManager.handle_player_disconnect(room.code, user.id)
    :ok = GenServer.call(pid, {:set_state, settled})
    {:ok, snapshot} = GameAdapter.get_snapshot(room.code)
    send(RoomManager, {:state_update, room.code, Map.put(snapshot, :transition_delay_ms, 0)})
    send(RoomManager, {:sweep_play, room.code, 0, 0})
    RoomManager.list_rooms()
    Process.sleep(Lifecycle.config(:sweep_trick_delay_ms) + 50)
    assert {:ok, ^settled} = GameAdapter.get_state(room.code)
    {:ok, _} = RoomManager.handle_player_reconnect(room.code, user.id)
    wait_for_progress(room.code, settled)
  end

  test "bots stop moving while the human is away, including a move already scheduled" do
    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.put(Application.fetch_env!(:pidro_server, Lifecycle), :dealer_selection_delay_ms, 0)
    )

    {room, user} = bot_table(false, :quick)
    {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)
    wait_for_bidding(room.code)
    {:ok, game} = GameAdapter.get_state(room.code)

    if game.current_turn == :north,
      do: {:ok, _} = GameAdapter.apply_action(room.code, :north, :pass)

    {:ok, before} = GameAdapter.get_snapshot(room.code)
    bot = room.seats[before.state.current_turn].bot_pid
    :ok = RoomManager.handle_player_disconnect(room.code, user.id)
    send(bot, :make_move)
    :sys.get_state(bot)
    assert {:ok, waiting} = GameAdapter.get_snapshot(room.code)
    assert Map.delete(waiting, :server_time_ms) == Map.delete(before, :server_time_ms)

    {:ok, _} = RoomManager.handle_player_reconnect(room.code, user.id)
    send(bot, :make_move)
    :sys.get_state(bot)
    {:ok, after_return} = GameAdapter.get_snapshot(room.code)
    assert after_return.state_revision > before.state_revision
  end

  test "all multiplayer humans past grace stay reclaimable without abandonments" do
    users = for _ <- 1..4, do: AccountsFixtures.user_fixture()
    [host | others] = users
    {:ok, room} = RoomManager.create_room(host.id)
    for user <- others, do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
    room = RoomFixtures.ready_room(room.code)
    {:ok, game} = GameSupervisor.get_game(room.code)

    for position <- [:east, :south, :west, :north] do
      :ok = RoomManager.handle_player_disconnect(room.code, room.seats[position].user_id)
      {:ok, _} = RoomManagerCase.expire_phase(room.code, position, :phase2_start)
      assert {:ok, _} = RoomManagerCase.expire_phase(room.code, position, :phase3_gone)
    end

    assert Process.alive?(game)
    assert Repo.aggregate(AbandonmentEvent, :count) == 0
    assert Repo.aggregate("game_stats", :count) == 0
    assert {:ok, returned} = RoomManager.handle_player_reconnect(room.code, host.id)
    assert returned.seats.north.user_id == host.id
  end

  test "restore preserves an existing absence and uses boot time for a connected human" do
    {room, user} = bot_table(true, :quick)
    :ok = RoomManager.handle_player_disconnect(room.code, user.id)
    absent_since = age_absence(room.code, 29)
    restore(room.code)
    assert {:ok, restored} = RoomManager.get_room(room.code)
    assert restored.seats.north.disconnected_at == absent_since
    assert restored.phase_timers == %{}
    sweep()
    assert {:ok, _} = RoomManager.get_room(room.code)
    age_absence(room.code, 30)
    sweep()
    assert {:error, :room_not_found} = RoomManager.get_room(room.code)

    {fresh, _} = bot_table(false, :quick)
    boot = DateTime.utc_now()
    restore(fresh.code)
    assert {:ok, restored} = RoomManager.get_room(fresh.code)
    assert DateTime.compare(restored.seats.north.disconnected_at, boot) != :lt
    assert restored.phase_timers == %{}
  end

  test "restore returns a legacy solo substitute to its human without restarting the clock" do
    {room, user} = bot_table(false, :quick)
    :ok = RoomManager.handle_player_disconnect(room.code, user.id)
    since = age_absence(room.code, 29)
    {:ok, away} = RoomManager.get_room(room.code)
    {:ok, grace} = PidroServer.Games.Room.Seat.start_grace(away.seats.north, DateTime.utc_now())
    {:ok, substitute} = PidroServer.Games.Room.Seat.substitute_bot(grace, self())
    substitute = %{substitute | bot_pid: nil}
    :sys.replace_state(RoomManager, &put_in(&1.rooms[room.code].seats.north, substitute))
    restore(room.code)
    assert {:ok, restored} = RoomManager.get_room(room.code)
    assert restored.seats.north.user_id == user.id
    assert restored.seats.north.occupant_type == :human
    assert restored.seats.north.status == :reconnecting
    assert restored.seats.north.disconnected_at == since
    assert restored.phase_timers == %{}
    assert Repo.aggregate(AbandonmentEvent, :count) == 0
    age_absence(room.code, 30)
    sweep()
    assert {:error, :room_not_found} = RoomManager.get_room(room.code)
  end

  defp bot_table(solo, pace) do
    user = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(user.id, %{solo: solo})

    for position <- [:east, :south, :west],
        do: {:ok, _} = BotManager.start_bot(room.code, position, :basic, 5_000)

    if pace == :own, do: {:ok, _} = RoomManager.set_pace(room.code, user.id, pace)
    {RoomFixtures.ready_room(room.code), user}
  end

  defp wait_for_bidding(code, attempts \\ 100) do
    case GameAdapter.get_state(code) do
      {:ok, %{phase: :bidding}} ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_bidding(code, attempts - 1)

      _ ->
        flunk("game did not reach bidding")
    end
  end

  defp wait_for_progress(code, before, attempts \\ 100) do
    {:ok, game} = GameAdapter.get_state(code)

    cond do
      length(game.events) > length(before.events) ->
        :ok

      attempts == 0 ->
        flunk("game did not resume")

      true ->
        Process.sleep(10)
        wait_for_progress(code, before, attempts - 1)
    end
  end

  defp age_absence(code, minutes) do
    since = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    :sys.replace_state(RoomManager, fn state ->
      put_in(state.rooms[code].seats.north.disconnected_at, since)
    end)

    since
  end

  defp sweep do
    send(RoomManager, :cleanup_abandoned_rooms)
    RoomManager.list_rooms()
  end

  defp restore(code) do
    :ok = RoomManager.release_rooms()
    :ok = Supervisor.terminate_child(PidroServer.Games.Supervisor, RoomManager)
    {:ok, _} = Supervisor.restart_child(PidroServer.Games.Supervisor, RoomManager)
    assert {:ok, _} = RoomManager.find_room(code)
  end
end
