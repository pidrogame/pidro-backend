defmodule PidroServer.Games.SubstituteSeatTest do
  @moduledoc """
  Tests for the substitute seat flow (Phase 8).

  Owner can open bot-filled seats for human substitutes, strangers can join
  :playing rooms with vacant seats, and owner can close vacant seats back to bots.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.Room.Config
  alias PidroServer.Games.RoomManager
  alias PidroServer.RoomManagerCase

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
      nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
      _pid -> :ok
    end

    :ok
  end

  # Creates a room with 4 players in :playing state.
  # Returns the room struct and a map of position => user_id.
  defp create_playing_room(attrs \\ %{name: "Substitute Test"}) do
    {:ok, room} = RoomManager.create_room("user1", attrs)
    {:ok, _, _} = RoomManager.join_room(room.code, "user2")
    {:ok, _, _} = RoomManager.join_room(room.code, "user3")
    {:ok, _, _} = RoomManager.join_room(room.code, "user4")
    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, playing_room} = RoomManager.get_room(room.code)

    assert playing_room.status == :playing

    player_positions =
      Enum.reduce(playing_room.seats, %{}, fn {pos, seat}, acc ->
        if seat.user_id, do: Map.put(acc, pos, seat.user_id), else: acc
      end)

    {playing_room, player_positions}
  end

  defp position_for(room, user_id) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if seat.user_id == user_id, do: pos
    end)
  end

  # Only deliberate departure releases a seat for another player.
  defp make_seat_bot_substitute(room, user_id) do
    position = position_for(room, user_id)
    :ok = RoomManager.handle_player_disconnect(room.code, user_id)

    # Trigger Phase 2: bot substitution
    {:ok, _} = RoomManagerCase.expire_phase(room.code, position, :phase2_start)
    :ok = RoomManager.leave_room(user_id)
    {:ok, room_after_p2} = RoomManager.get_room(room.code)

    {room_after_p2, position}
  end

  describe "open_seat — owner opens a bot-filled seat" do
    test "a new human does not inherit the departing player's connection measurements" do
      {room, _} = create_playing_room()
      position = position_for(room, "user2")

      :sys.replace_state(RoomManager, fn state ->
        update_in(
          state.rooms[room.code].seats[position].connection_stats.started_ms,
          &(&1 - 60_000)
        )
      end)

      send(RoomManager, :check_connections)
      RoomManager.get_room(room.code)
      assert_receive {:connection_ping, "user2", %{id: id}}
      :ok = RoomManager.connection_activity(room.code, "user2", id)
      {with_bot, position} = make_seat_bot_substitute(room, "user2")

      {:ok, _} =
        RoomManager.open_seat(room.code, position, "user1", with_bot.seats[position].decision_id)

      {:ok, replacement, ^position} = RoomManager.join_room(room.code, "replacement")
      assert replacement.seats[position].connection_stats != nil
      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 25}})
      RoomManager.get_room(room.code)
      await_tasks()
      assert [old] = PidroServer.Stats.connection_games("user2")
      assert [new] = PidroServer.Stats.connection_games("replacement")
      assert old.checks_sent == 1
      assert old.drops == 1
      assert old.duration_seconds >= 60
      assert new.checks_sent == 0
      assert new.drops == 0
      assert new.median_ms == nil
      assert new.disconnected_seconds == 0
      assert new.duration_seconds < old.duration_seconds
    end

    test "a reserved seat cannot be opened, and host reclaim preserves another pending decision" do
      {room, _} = create_playing_room()
      {_, departed} = make_seat_bot_substitute(room, "user2")
      {:ok, before} = RoomManager.get_seat_lifecycle(room.code)
      :ok = RoomManager.handle_player_disconnect(room.code, "user1")
      {:ok, _} = RoomManagerCase.expire_phase(room.code, :north, :phase2_start)
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, "user1")
      {:ok, after_reclaim} = RoomManager.get_seat_lifecycle(room.code)
      assert after_reclaim.owner_id == "user1"
      assert after_reclaim.seats.north.decision == nil
      assert after_reclaim.seats[departed].decision == before.seats[departed].decision

      :ok = RoomManager.handle_player_disconnect(room.code, "user4")
      {:ok, reserved} = RoomManagerCase.expire_phase(room.code, :west, :phase2_start)

      for id <- [nil, before.seats[departed].decision.id] do
        assert {:error, :stale_decision} = RoomManager.open_seat(room.code, :west, "user1", id)
      end

      {:ok, reclaimed} = RoomManager.handle_player_reconnect(room.code, "user4")
      assert reclaimed.seats.west.user_id == "user4"
      refute Process.alive?(reserved.seats.west.bot_pid)
    end

    test "Keep Bot survives repeat Leave and owner transfer, without consuming other decisions" do
      {room, _} = create_playing_room()
      {with_bot, position} = make_seat_bot_substitute(room, "user2")
      id = with_bot.seats[position].decision_id
      pid = with_bot.seats[position].bot_pid
      assert {:error, :not_owner} = RoomManager.keep_bot(room.code, position, "user3", id)
      assert {:error, :stale_decision} = RoomManager.keep_bot(room.code, position, "user1", nil)
      {:ok, kept} = RoomManager.keep_bot(room.code, position, "user1", id)
      assert kept.seat_lifecycle_revision > with_bot.seat_lifecycle_revision
      assert kept.seats[position].bot_pid == pid
      assert Process.alive?(pid)
      assert kept.seats[position].decision_id == nil
      assert {:error, :stale_decision} = RoomManager.open_seat(room.code, position, "user1", id)
      assert {:error, :stale_decision} = RoomManager.keep_bot(room.code, position, "user1", id)
      assert {:error, :not_in_room} = RoomManager.leave_room("user2")
      :ok = RoomManager.leave_room("user1")
      {:ok, transferred} = RoomManager.get_seat_lifecycle(room.code)
      assert transferred.owner_id == "user3"
      assert transferred.seats[position].decision == nil
      assert is_binary(transferred.seats.north.decision.id)
      # Keeping a bot does not prohibit a later deliberate manual opening.
      {:ok, _} = RoomManager.open_seat(room.code, position, "user3")
    end

    test "old decision cannot affect a filled seat or its next departure" do
      {room, _} = create_playing_room()
      {with_bot, position} = make_seat_bot_substitute(room, "user2")
      id = with_bot.seats[position].decision_id
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1", id)
      {:ok, _, ^position} = RoomManager.join_as_substitute(room.code, "new-player")

      for action <- [:open_seat, :keep_bot] do
        assert {:error, :seat_not_bot_substitute} =
                 apply(RoomManager, action, [room.code, position, "user1", id])
      end

      {:ok, filled} = RoomManager.get_seat_lifecycle(room.code)
      assert filled.seats[position].player_id == "new-player"
      assert filled.seats[position].decision == nil
      :ok = RoomManager.leave_room("new-player")
      assert {:error, :stale_decision} = RoomManager.keep_bot(room.code, position, "user1", id)
      {:ok, next} = RoomManager.get_seat_lifecycle(room.code)
      assert next.seats[position].decision.id != id
    end

    test "owner can open a bot_substitute seat — seat becomes vacant" do
      {room, _positions} = create_playing_room()

      # Pick a non-owner player to disconnect and cascade to bot_substitute
      non_owner_id = "user2"
      {room_with_bot, position} = make_seat_bot_substitute(room, non_owner_id)

      # Verify seat is bot_substitute before opening
      seat = room_with_bot.seats[position]
      assert seat.status == :bot_substitute
      assert seat.occupant_type == :bot

      # Owner opens the seat
      {:ok, updated_room} = RoomManager.open_seat(room.code, position, "user1")

      opened_seat = updated_room.seats[position]
      assert opened_seat.occupant_type == :vacant
      assert opened_seat.status == nil
      assert opened_seat.bot_pid == nil
      assert opened_seat.user_id == nil
    end

    test "non-owner cannot open a seat" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      # user3 is not the owner
      assert {:error, :not_owner} = RoomManager.open_seat(room.code, position, "user3")
    end

    test "cannot open a seat that isn't bot_substitute" do
      {room, _positions} = create_playing_room()

      # Try to open a connected human seat
      position = position_for(room, "user2")

      assert {:error, :seat_not_bot_substitute} =
               RoomManager.open_seat(room.code, position, "user1")
    end

    test "cannot open a seat in a non-playing room" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Waiting Room"})

      assert {:error, :room_not_playing} =
               RoomManager.open_seat(room.code, :north, "user1")
    end

    test "opening a seat terminates the bot process" do
      {room, _positions} = create_playing_room()
      {room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      bot_pid = room_with_bot.seats[position].bot_pid
      assert is_pid(bot_pid)
      assert Process.alive?(bot_pid)

      {:ok, _updated_room} = RoomManager.open_seat(room.code, position, "user1")

      # Bot process should be terminated
      refute Process.alive?(bot_pid)
    end
  end

  describe "join_as_substitute — stranger joins a playing room with vacant seat" do
    test "a guest cannot join as a substitute" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")
      guest = AccountsFixtures.guest_fixture()

      assert {:error, :account_required} = RoomManager.join_as_substitute(room.code, guest)

      assert {:ok, unchanged} = RoomManager.get_room(room.code)
      assert unchanged.seats[position].occupant_type == :vacant
      refute Map.has_key?(:sys.get_state(RoomManager).player_rooms, guest.id)
    end

    test "stranger can join a playing room with a vacant seat" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      # Owner opens the seat
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      # Stranger joins
      {:ok, updated_room, joined_position} =
        RoomManager.join_as_substitute(room.code, "stranger1")

      assert joined_position == position

      seat = updated_room.seats[joined_position]
      assert seat.occupant_type == :human
      assert seat.status == :connected
      assert seat.user_id == "stranger1"
    end

    test "sitting in as a substitute with people releases the player's holds elsewhere" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      [host, friend] = for _ <- 1..2, do: AccountsFixtures.user_fixture()
      {:ok, held} = RoomManager.create_room(host.id, %{seat_holds: %{south: friend.id}})
      held_code = held.code
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{held_code}")

      {:ok, _, ^position} = RoomManager.join_as_substitute(room.code, friend.id)

      assert_receive {:seat_invitation_declined,
                      %{position: :south, user_id: _, reason: "sat_elsewhere"}}

      assert {:ok, %{config: %{seat_holds: holds}}} = RoomManager.get_room(held_code)
      assert holds == %{}
    end

    test "a requested seat is honoured, and a taken one answers seat_taken" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")
      taken = Enum.find([:north, :east, :south, :west], &(&1 != position))

      assert {:error, :seat_taken} = RoomManager.join_room(room.code, "stranger1", taken)

      assert {:ok, updated_room, ^position} =
               RoomManager.join_room(room.code, "stranger1", position)

      assert updated_room.seats[position].user_id == "stranger1"
    end

    test "AE5: the room config is unchanged after a substitute seat is opened and reclaimed" do
      {:ok, config} = Config.new(name: "Friday", bot_difficulty: :smart)
      {room, _positions} = create_playing_room(config)
      assert room.config == config

      {room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      assert room_with_bot.seats[position].status == :bot_substitute
      assert room_with_bot.config == config

      {:ok, opened_room} = RoomManager.open_seat(room.code, position, "user1")
      assert opened_room.config == config

      {:ok, claimed_room, ^position} = RoomManager.join_as_substitute(room.code, "stranger1")
      assert claimed_room.seats[position].user_id == "stranger1"
      assert claimed_room.config == config
      assert {:ok, %{config: ^config}} = RoomManager.get_room(room.code)
    end

    test "substitute is placed in the correct position in positions map" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      {:ok, updated_room, joined_position} =
        RoomManager.join_as_substitute(room.code, "stranger1")

      assert updated_room.positions[joined_position] == "stranger1"
    end

    test "cannot join as substitute when no vacant seat exists" do
      {room, _positions} = create_playing_room()

      # All seats are occupied by humans — no vacant seats
      assert {:error, :no_vacant_seat} =
               RoomManager.join_as_substitute(room.code, "stranger1")
    end

    test "cannot join as substitute in a non-playing room" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Waiting Room"})

      assert {:error, :room_not_playing} =
               RoomManager.join_as_substitute(room.code, "stranger1")
    end
  end

  describe "close_seat — owner closes a vacant seat back to bot" do
    test "owner can close a vacant seat back to bot" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      # Verify seat is vacant
      {:ok, open_room} = RoomManager.get_room(room.code)
      assert open_room.seats[position].occupant_type == :vacant

      # Owner closes the seat
      {:ok, updated_room} = RoomManager.close_seat(room.code, position, "user1")

      closed_seat = updated_room.seats[position]
      assert closed_seat.occupant_type == :bot
      assert closed_seat.status == :bot_substitute
      assert is_pid(closed_seat.bot_pid)
      assert Process.alive?(closed_seat.bot_pid)
      assert closed_seat.reserved_for == nil
    end

    test "non-owner cannot close a seat" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      assert {:error, :not_owner} = RoomManager.close_seat(room.code, position, "user3")
    end

    test "cannot close a seat that isn't vacant" do
      {room, _positions} = create_playing_room()

      # Seat is occupied by a human, not vacant
      position = position_for(room, "user2")

      assert {:error, :seat_not_vacant} =
               RoomManager.close_seat(room.code, position, "user1")
    end
  end

  describe "full substitute seat flow end-to-end" do
    test "disconnect → bot → open → substitute joins → seat filled" do
      {room, _positions} = create_playing_room()

      # Step 1: Player disconnects and gets bot substituted
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      # Step 2: Owner opens the seat
      {:ok, opened_room} = RoomManager.open_seat(room.code, position, "user1")
      assert opened_room.seats[position].occupant_type == :vacant

      # Step 3: Stranger joins as substitute
      {:ok, final_room, joined_pos} =
        RoomManager.join_as_substitute(room.code, "stranger1")

      assert joined_pos == position
      assert final_room.seats[position].user_id == "stranger1"
      assert final_room.seats[position].occupant_type == :human
      assert final_room.seats[position].status == :connected
    end

    test "open seat broadcasts substitute_available event" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      assert_receive {:substitute_available, %{position: ^position}}
    end

    test "close seat broadcasts substitute_seat_closed event" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {:ok, _} = RoomManager.close_seat(room.code, position, "user1")

      assert_receive {:substitute_seat_closed, %{position: ^position}}
    end

    test "substitute_joined is broadcast when stranger joins" do
      {room, _positions} = create_playing_room()
      {_room_with_bot, position} = make_seat_bot_substitute(room, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {:ok, _, _} = RoomManager.join_as_substitute(room.code, "stranger1")

      assert_receive {:substitute_joined, %{position: ^position, user_id: "stranger1"}}
    end
  end
end
