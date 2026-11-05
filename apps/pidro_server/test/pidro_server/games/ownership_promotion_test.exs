defmodule PidroServer.Games.OwnershipPromotionTest do
  @moduledoc """
  Tests for ownership auto-promotion when the owner explicitly leaves a
  :playing room, including after a connection drop.

  Promotion priority: partner first (N↔S, E↔W), then remaining positions
  sorted by joined_at. If no connected humans remain, returns {:no_humans, room}.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.RoomManager
  alias PidroServer.Games.Room.Seat
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
  # user1 is always the host/owner.
  defp create_playing_room do
    {:ok, room} = RoomManager.create_room("user1", %{name: "Ownership Test"})
    {:ok, _, _} = RoomManager.join_room(room.code, "user2")
    {:ok, _, _} = RoomManager.join_room(room.code, "user3")
    {:ok, _, _} = RoomManager.join_room(room.code, "user4")
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

  defp position_for(room, user_id) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if seat.user_id == user_id, do: pos
    end)
  end

  defp owner_position(room) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if Seat.owner?(seat), do: pos
    end)
  end

  defp partner_position(:north), do: :south
  defp partner_position(:south), do: :north
  defp partner_position(:east), do: :west
  defp partner_position(:west), do: :east

  # Disconnect, substitute, then deliberately leave (makes bot permanent).
  defp trigger_full_cascade(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)

    # A disconnect alone never releases ownership.
    {:ok, _} = RoomManagerCase.expire_phase(room_code, position, :phase2_start)
    :ok = RoomManager.leave_room(user_id)
    {:ok, updated_room} = RoomManager.get_room(room_code)

    {updated_room, position}
  end

  # Disconnect and trigger Phase 2 only (bot substitute, still reclaimable).
  defp trigger_phase2(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)

    {:ok, updated_room} = RoomManagerCase.expire_phase(room_code, position, :phase2_start)

    {updated_room, position}
  end

  describe "owner disconnect (Phase 3) promotes partner" do
    test "partner is promoted to owner when owner's bot becomes permanent" do
      {room, _positions} = create_playing_room()
      owner_pos = owner_position(room)
      partner_pos = partner_position(owner_pos)
      partner_user_id = room.seats[partner_pos].user_id

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      # Full cascade on owner (user1)
      {updated_room, _pos} = trigger_full_cascade(room.code, "user1")

      # Partner should now be owner
      assert updated_room.seats[partner_pos].is_owner == true
      assert updated_room.host_id == partner_user_id

      # Old owner seat should not be owner
      assert updated_room.seats[owner_pos].is_owner == false

      # owner_changed event should have been broadcast
      assert_receive {:owner_changed,
                      %{new_owner_id: ^partner_user_id, new_owner_position: ^partner_pos}},
                     500
    end
  end

  describe "owner disconnect promotes opponent if partner also disconnected" do
    test "promotion skips disconnected partner and goes to next connected human" do
      {room, _positions} = create_playing_room()
      owner_pos = owner_position(room)
      partner_pos = partner_position(owner_pos)
      partner_user_id = room.seats[partner_pos].user_id

      # Disconnect the partner first (full cascade — permanent bot)
      {_room_after_partner, _} = trigger_full_cascade(room.code, partner_user_id)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      # Now disconnect the owner (full cascade)
      {updated_room, _pos} = trigger_full_cascade(room.code, "user1")

      # Partner is a permanent bot, so the longest-joined connected opponent wins.
      opponent_positions = [:north, :east, :south, :west] -- [owner_pos, partner_pos]

      expected_owner_pos =
        Enum.min_by(opponent_positions, fn position ->
          DateTime.to_unix(updated_room.seats[position].joined_at, :microsecond)
        end)

      new_owner_pos = owner_position(updated_room)
      assert new_owner_pos == expected_owner_pos

      new_owner_seat = updated_room.seats[new_owner_pos]
      assert Seat.connected_human?(new_owner_seat)
      assert updated_room.host_id == new_owner_seat.user_id

      # owner_changed event should have been broadcast
      assert_receive {:owner_changed, %{new_owner_id: _, new_owner_position: ^new_owner_pos}},
                     500
    end
  end

  describe "owner reconnect during grace keeps ownership" do
    test "owner reclaims seat during Phase 2 and retains ownership" do
      {room, _positions} = create_playing_room()
      owner_pos = owner_position(room)

      # Phase 2 only (bot substitute, still reclaimable)
      {phase2_room, _pos} = trigger_phase2(room.code, "user1")

      # Owner seat should still have is_owner (bot substitute preserves it)
      assert phase2_room.seats[owner_pos].is_owner == true

      # Reconnect during Phase 2
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, "user1")

      # Owner should retain ownership
      seat = reconnected_room.seats[owner_pos]
      assert seat.is_owner == true
      assert seat.status == :connected
      assert seat.user_id == "user1"
      assert reconnected_room.host_id == "user1"
    end
  end

  describe "explicit leave triggers promotion" do
    test "owner leaving a :playing room promotes next human" do
      {room, _positions} = create_playing_room()
      owner_pos = owner_position(room)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.leave_room("user1")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Someone else should be owner now
      new_owner_pos = owner_position(updated_room)
      assert new_owner_pos != nil
      assert new_owner_pos != owner_pos

      new_owner_seat = updated_room.seats[new_owner_pos]
      assert Seat.connected_human?(new_owner_seat)
      assert updated_room.host_id == new_owner_seat.user_id

      # owner_changed event
      assert_receive {:owner_changed, %{new_owner_id: _, new_owner_position: _}}, 500
    end
  end

  describe "all humans disconnected returns {:no_humans, room}" do
    test "no promotion when all humans disconnect permanently" do
      {room, _positions} = create_playing_room()
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      # Disconnect all 4 players through full cascade
      trigger_full_cascade(room.code, "user1")
      trigger_full_cascade(room.code, "user2")
      trigger_full_cascade(room.code, "user3")
      :ok = RoomManager.handle_player_disconnect(room.code, "user4")
      position = position_for(room, "user4")
      {:ok, _} = RoomManagerCase.expire_phase(room.code, position, :phase2_start)

      assert :ok = RoomManager.leave_room("user4")
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)

      assert_receive {:room_updated, %{host_id: nil} = updated_room}

      # All seats should be bots with no reserved_for
      for {_pos, seat} <- updated_room.seats do
        assert seat.occupant_type == :bot
        assert seat.reserved_for == nil
      end

      assert updated_room.host_id == nil
      refute Enum.any?(updated_room.seats, fn {_pos, seat} -> Seat.owner?(seat) end)
      assert_receive {:owner_changed, %{new_owner_id: nil, new_owner_position: nil}}, 500
    end

    test "all non-owner humans disconnect first, then owner — no connected owner remains" do
      {room, _positions} = create_playing_room()
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      # Disconnect non-owners first
      trigger_full_cascade(room.code, "user2")
      trigger_full_cascade(room.code, "user3")
      trigger_full_cascade(room.code, "user4")

      # Owner is still connected
      {:ok, mid_room} = RoomManager.get_room(room.code)
      owner_pos = owner_position(mid_room)
      assert mid_room.seats[owner_pos].user_id == "user1"
      assert Seat.connected_human?(mid_room.seats[owner_pos])

      # Now disconnect owner — no one left to promote to
      :ok = RoomManager.handle_player_disconnect(room.code, "user1")
      {:ok, _} = RoomManagerCase.expire_phase(room.code, owner_pos, :phase2_start)

      assert :ok = RoomManager.leave_room("user1")
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)

      assert_receive {:room_updated, %{host_id: nil} = final_room}

      # No connected human should be owner
      connected_humans =
        Enum.filter(final_room.seats, fn {_pos, seat} ->
          Seat.connected_human?(seat)
        end)

      assert connected_humans == []
      assert final_room.host_id == nil
      refute Enum.any?(final_room.seats, fn {_pos, seat} -> Seat.owner?(seat) end)
      assert_receive {:owner_changed, %{new_owner_id: nil, new_owner_position: nil}}, 500
    end
  end

  describe "ownerless room reclamation" do
    test "a Phase 1 returning human becomes owner after the owner permanently departs" do
      {room, _positions} = create_playing_room()

      for user_id <- ["user2", "user3", "user4"] do
        :ok = RoomManager.handle_player_disconnect(room.code, user_id)
      end

      {ownerless_room, _} = trigger_full_cascade(room.code, "user1")
      assert ownerless_room.host_id == nil

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      returning_pos = position_for(ownerless_room, "user2")
      {:ok, reclaimed_room} = RoomManager.handle_player_reconnect(room.code, "user2")

      assert reclaimed_room.host_id == "user2"
      assert reclaimed_room.seats[returning_pos].is_owner

      assert_receive {:owner_changed,
                      %{new_owner_id: "user2", new_owner_position: ^returning_pos}},
                     500
    end

    test "a Phase 2 returning human becomes owner, stops its bot, and can manage a substitute seat" do
      {room, _positions} = create_playing_room()
      {phase2_room, returning_pos} = trigger_phase2(room.code, "user2")
      returning_bot = phase2_room.seats[returning_pos].bot_pid
      {room_with_second_bot, open_pos} = trigger_phase2(room.code, "user3")
      assert Process.alive?(returning_bot)

      :ok = RoomManager.handle_player_disconnect(room.code, "user4")
      {ownerless_room, _} = trigger_full_cascade(room.code, "user1")
      assert ownerless_room.host_id == nil

      {:ok, reclaimed_room} = RoomManager.handle_player_reconnect(room.code, "user2")
      assert reclaimed_room.host_id == "user2"
      assert reclaimed_room.seats[returning_pos].is_owner
      refute Process.alive?(returning_bot)

      assert room_with_second_bot.seats[open_pos].status == :bot_substitute
      :ok = RoomManager.leave_room("user3")
      {:ok, opened_room} = RoomManager.open_seat(room.code, open_pos, "user2")
      assert opened_room.seats[open_pos].occupant_type == :vacant
      {:ok, closed_room} = RoomManager.close_seat(room.code, open_pos, "user2")
      assert closed_room.seats[open_pos].status == :bot_substitute
    end

    test "a substitute joining an already-open seat restores ownership to an ownerless room" do
      {room, _positions} = create_playing_room()
      {_gone, position} = trigger_full_cascade(room.code, "user2")
      {:ok, _} = RoomManager.open_seat(room.code, position, "user1")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")
      :ok = RoomManager.handle_player_disconnect(room.code, "user4")
      :ok = RoomManager.leave_room("user1")
      {:ok, ownerless} = RoomManager.get_room(room.code)
      assert ownerless.host_id == nil

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      {:ok, joined, ^position} = RoomManager.join_as_substitute(room.code, "new-human")
      assert joined.host_id == "new-human"
      assert joined.seats[position].is_owner
      assert_receive {:owner_changed, %{new_owner_id: "new-human", new_owner_position: ^position}}
      {:ok, stored} = RoomManager.get_room(room.code)
      assert stored.host_id == "new-human"
    end

    test "a returning human does not steal ownership from the promoted owner" do
      {room, _positions} = create_playing_room()
      {_phase2_room, returning_pos} = trigger_phase2(room.code, "user2")
      {promoted_room, _} = trigger_full_cascade(room.code, "user1")
      existing_owner_id = promoted_room.host_id
      existing_owner_pos = owner_position(promoted_room)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, "user2")

      assert reconnected_room.host_id == existing_owner_id
      assert owner_position(reconnected_room) == existing_owner_pos
      refute reconnected_room.seats[returning_pos].is_owner
      refute_receive {:owner_changed, _}, 100
    end
  end

  test "repeated Phase 3 envelope is ignored without replacing the bot or rebroadcasting ownership" do
    {room, _positions} = create_playing_room()
    owner_pos = owner_position(room)
    :ok = RoomManager.handle_player_disconnect(room.code, "user1")
    {:ok, _} = RoomManagerCase.expire_phase(room.code, owner_pos, :phase2_start)
    {:ok, phase2_room} = RoomManager.get_room(room.code)
    phase3_ref = Map.fetch!(phase2_room.phase_timers, owner_pos)

    Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
    :ok = RoomManager.leave_room("user1")
    {:ok, permanent_room} = RoomManager.get_room(room.code)
    controller = permanent_room.seats[owner_pos].bot_pid
    assert_receive {:owner_changed, _}, 500

    send(RoomManager, {:timeout, phase3_ref, {:phase3_gone, room.code, owner_pos}})
    {:ok, unchanged_room} = RoomManager.get_room(room.code)

    assert unchanged_room.seats[owner_pos].bot_pid == controller
    refute_receive {:owner_changed, _}, 100
  end
end
