defmodule PidroServer.Games.LobbyFilteringTest do
  @moduledoc """
  Tests for `RoomManager.list_lobby/1` — categorized lobby data.

  Categories:
  - my_rejoinable: :playing rooms where user has a reserved seat
  - open_tables: :waiting rooms with vacant seats
  - substitute_needed: :playing rooms with vacant seats (opened by owner)
  - spectatable: :playing rooms with spectator capacity remaining

  Rooms with zero connected humans appear in no category.
  """

  use PidroServer.DataCase, async: false

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

  # Creates a :waiting room with host and returns room struct.
  defp create_waiting_room(host_id, opts \\ %{}) do
    {:ok, room} = RoomManager.create_room(host_id, Map.merge(%{name: "Test Room"}, opts))
    {:ok, room} = RoomManager.get_room(room.code)
    room
  end

  # Creates a room with 4 players in :playing state.
  # Uses unique player IDs based on host to avoid :already_in_room errors.
  defp create_playing_room(host_id \\ "user1") do
    room = create_waiting_room(host_id)
    {:ok, _, _} = RoomManager.join_room(room.code, "#{host_id}_p2")
    {:ok, _, _} = RoomManager.join_room(room.code, "#{host_id}_p3")
    {:ok, _, _} = RoomManager.join_room(room.code, "#{host_id}_p4")
    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, playing_room} = RoomManager.get_room(room.code)
    assert playing_room.status == :playing
    playing_room
  end

  defp position_for(room, user_id) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if seat.user_id == user_id, do: pos
    end)
  end

  # Disconnect then deliberately leave (makes bot permanent).
  defp trigger_full_cascade(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)

    {:ok, _} = RoomManagerCase.expire_phase(room_code, position, :phase2_start)
    :ok = RoomManager.leave_room(user_id)
    {:ok, updated_room} = RoomManager.get_room(room_code)

    {updated_room, position}
  end

  # Disconnect only (Phase 1 — seat becomes :reconnecting).
  defp trigger_disconnect(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)
    {room, position}
  end

  # Disconnect and trigger Phase 2 only (bot substitute, still reclaimable).
  defp trigger_phase2(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)

    {:ok, updated_room} = RoomManagerCase.expire_phase(room_code, position, :phase2_start)

    {updated_room, position}
  end

  describe "open_tables" do
    test "returns waiting rooms with vacant seats" do
      room = create_waiting_room("host1")

      lobby = RoomManager.list_lobby(nil)

      assert length(lobby.open_tables) == 1
      assert hd(lobby.open_tables).code == room.code
    end

    test "does not return full waiting rooms" do
      PidroServer.RoomFixtures.waiting_room_fixture(seated: 4)

      lobby = RoomManager.list_lobby(nil)

      assert lobby.open_tables == []
    end

    test "returns multiple waiting rooms" do
      room1 = create_waiting_room("host1")
      room2 = create_waiting_room("host2")

      lobby = RoomManager.list_lobby(nil)

      codes = Enum.map(lobby.open_tables, & &1.code)
      assert room1.code in codes
      assert room2.code in codes
    end

    test "does not return single-player tables" do
      _solo_room = create_waiting_room("solo_host", %{solo: true})
      room = create_waiting_room("host1")

      lobby = RoomManager.list_lobby(nil)

      assert length(lobby.open_tables) == 1
      assert hd(lobby.open_tables).code == room.code
    end
  end

  describe "my_rejoinable" do
    test "returns rooms where user has a reserved seat in :reconnecting" do
      room = create_playing_room("user1")

      # Disconnect user1 (Phase 1 only — seat is :reconnecting)
      {_updated, _pos} = trigger_disconnect(room.code, "user1")

      lobby = RoomManager.list_lobby("user1")

      assert length(lobby.my_rejoinable) == 1
      assert hd(lobby.my_rejoinable).code == room.code
    end

    test "returns rooms where user has a reserved seat in :bot_substitute" do
      room = create_playing_room("user1")

      # Trigger Phase 2 — bot playing, seat still reserved for user1
      {_updated, _pos} = trigger_phase2(room.code, "user1")

      lobby = RoomManager.list_lobby("user1")

      assert length(lobby.my_rejoinable) == 1
      assert hd(lobby.my_rejoinable).code == room.code
    end

    test "does not return rooms for a different user" do
      room = create_playing_room("user1")
      {_updated, _pos} = trigger_disconnect(room.code, "user1")

      # Different user should not see user1's reserved seat
      lobby = RoomManager.list_lobby("other_user")

      assert lobby.my_rejoinable == []
    end

    test "does not return rooms after intentional leave (permanent bot)" do
      room = create_playing_room("user1")

      # Full cascade — bot becomes permanent, reserved_for cleared
      {_updated, _pos} = trigger_full_cascade(room.code, "user1")

      lobby = RoomManager.list_lobby("user1")

      assert lobby.my_rejoinable == []
    end

    test "returns empty list for nil user" do
      room = create_playing_room("user1")
      {_updated, _pos} = trigger_disconnect(room.code, "user1")

      lobby = RoomManager.list_lobby(nil)

      assert lobby.my_rejoinable == []
    end
  end

  describe "spectatable" do
    test "playing rooms appear in spectatable" do
      room = create_playing_room()

      lobby = RoomManager.list_lobby(nil)

      assert length(lobby.spectatable) == 1
      assert hd(lobby.spectatable).code == room.code
    end

    test "multiple playing rooms appear in spectatable" do
      room1 = create_playing_room("host1")
      room2 = create_playing_room("host2")

      lobby = RoomManager.list_lobby(nil)

      codes = Enum.map(lobby.spectatable, & &1.code)
      assert room1.code in codes
      assert room2.code in codes
    end

    test "waiting rooms do not appear in spectatable" do
      _room = create_waiting_room("host1")

      lobby = RoomManager.list_lobby(nil)

      assert lobby.spectatable == []
    end
  end

  describe "rooms with zero connected humans" do
    test "appear in no category" do
      room = create_playing_room("user1")

      # Disconnect all 4 players permanently
      trigger_full_cascade(room.code, "user1")
      trigger_full_cascade(room.code, "user1_p2")
      trigger_full_cascade(room.code, "user1_p3")
      :ok = RoomManager.handle_player_disconnect(room.code, "user1_p4")
      position = position_for(room, "user1_p4")
      {:ok, _} = RoomManagerCase.expire_phase(room.code, position, :phase2_start)

      assert :ok = RoomManager.leave_room("user1_p4")
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)

      lobby = RoomManager.list_lobby("user1")

      assert lobby.my_rejoinable == []
      assert lobby.open_tables == []
      assert lobby.substitute_needed == []
      assert lobby.spectatable == []
    end
  end

  describe "room state transitions" do
    test "room moves from open_tables to spectatable when full" do
      room = create_waiting_room("user1")

      # Room should be in open_tables
      lobby_before = RoomManager.list_lobby(nil)
      assert length(lobby_before.open_tables) == 1
      assert lobby_before.spectatable == []

      # Fill the room — transitions to :playing
      {:ok, _, _} = RoomManager.join_room(room.code, "user1_p2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user1_p3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user1_p4")
      PidroServer.RoomFixtures.ready_room(room.code)

      # Room should now be in spectatable, not open_tables
      lobby_after = RoomManager.list_lobby(nil)
      assert lobby_after.open_tables == []
      assert length(lobby_after.spectatable) == 1
      assert hd(lobby_after.spectatable).code == room.code
    end
  end
end
