defmodule PidroServer.Games.RoomCleanupTest do
  @moduledoc """
  Tests for stale room cleanup (Feature 6.1, 6.2):

  - Zero-human room auto-close after TTL
  - Auto-close cancellation when a human joins before TTL
  - Startup sweep removes orphaned :playing rooms and stale :waiting rooms
  - Health check cleans up dead bot_pid references
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Games.{Lifecycle, RoomManager}
  alias PidroServer.RoomManagerCase

  @user1 "00000000-0000-0000-0000-000000000001"
  @user2 "00000000-0000-0000-0000-000000000002"
  @user3 "00000000-0000-0000-0000-000000000003"
  @user4 "00000000-0000-0000-0000-000000000004"

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
  defp create_playing_room do
    {:ok, room} = RoomManager.create_room(@user1, %{name: "Cleanup Test"})
    {:ok, _, _} = RoomManager.join_room(room.code, @user2)
    {:ok, _, _} = RoomManager.join_room(room.code, @user3)
    {:ok, _, _} = RoomManager.join_room(room.code, @user4)
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

  # Trigger full disconnect cascade (Phase 1 → Phase 2 → Phase 3) for a player.
  defp trigger_full_cascade(room_code, user_id) do
    :ok = RoomManager.handle_player_disconnect(room_code, user_id)
    {:ok, room} = RoomManager.get_room(room_code)
    position = position_for(room, user_id)

    {:ok, _} = RoomManagerCase.expire_phase(room_code, position, :phase2_start)
    {:ok, updated_room} = RoomManagerCase.expire_phase(room_code, position, :phase3_gone)

    {updated_room, position}
  end

  defp disconnect_into_grace(room, user_id) do
    :ok = RoomManager.handle_player_disconnect(room.code, user_id)
    {:ok, _} = RoomManagerCase.expire_phase(room.code, position_for(room, user_id), :phase2_start)
  end

  describe "zero-human room auto-close" do
    test "playing room closes when its last human's grace expires" do
      room = create_playing_room()

      # Disconnect all 4 players through full cascade
      trigger_full_cascade(room.code, @user1)
      trigger_full_cascade(room.code, @user2)
      trigger_full_cascade(room.code, @user3)
      disconnect_into_grace(room, @user4)

      assert {:error, :room_not_found} =
               RoomManagerCase.expire_phase(room.code, position_for(room, @user4), :phase3_gone)

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "an empty-room close scheduled by an earlier game in the room does nothing" do
      room = create_playing_room()

      trigger_full_cascade(room.code, @user1)
      trigger_full_cascade(room.code, @user2)
      trigger_full_cascade(room.code, @user3)
      disconnect_into_grace(room, @user4)

      send(
        GenServer.whereis(RoomManager),
        {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
      )

      # This room is on game 1; a timer from "game 0" is not its timer.
      send(GenServer.whereis(RoomManager), {:auto_close_empty_room, room.code, 0})
      _ = RoomManager.list_rooms()

      assert {:ok, %{status: :finished}} = RoomManager.get_room(room.code)
    end

    test "finished room closes after auto_close_empty_room fires with zero connected humans" do
      room = create_playing_room()

      trigger_full_cascade(room.code, @user1)
      trigger_full_cascade(room.code, @user2)
      trigger_full_cascade(room.code, @user3)
      disconnect_into_grace(room, @user4)

      send(
        GenServer.whereis(RoomManager),
        {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
      )

      send(GenServer.whereis(RoomManager), {:auto_close_empty_room, room.code, 1})

      _ = RoomManager.list_rooms()

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "auto-close is cancelled if a human joins before TTL" do
      room = create_playing_room()

      trigger_full_cascade(room.code, @user1)
      trigger_full_cascade(room.code, @user2)
      trigger_full_cascade(room.code, @user3)
      disconnect_into_grace(room, @user4)
      send(RoomManager, {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}})
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, @user4)
      send(GenServer.whereis(RoomManager), {:auto_close_empty_room, room.code, 1})

      # Synchronize
      _ = RoomManager.list_rooms()

      assert {:ok, %{status: :finished}} = RoomManager.get_room(room.code)
    end
  end

  describe "startup sweep" do
    test "keeps :playing rooms while the last human can still reclaim" do
      room = create_playing_room()

      # Disconnect all players through full cascade
      trigger_full_cascade(room.code, @user1)
      trigger_full_cascade(room.code, @user2)
      trigger_full_cascade(room.code, @user3)
      disconnect_into_grace(room, @user4)

      # Room exists but has zero connected humans
      {:ok, _} = RoomManager.get_room(room.code)

      # Trigger startup sweep manually
      send(GenServer.whereis(RoomManager), :startup_sweep)

      # Synchronize
      _ = RoomManager.list_rooms()

      # Room should remain because the game process is still running.
      assert {:ok, _} = RoomManager.get_room(room.code)
    end

    test "removes finished rooms with zero connected humans" do
      room = create_playing_room()

      trigger_full_cascade(room.code, @user1)
      trigger_full_cascade(room.code, @user2)
      trigger_full_cascade(room.code, @user3)
      disconnect_into_grace(room, @user4)

      send(
        GenServer.whereis(RoomManager),
        {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
      )

      send(GenServer.whereis(RoomManager), :startup_sweep)

      _ = RoomManager.list_rooms()

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "removes stale :waiting rooms older than idle_waiting_ttl" do
      {:ok, room} = RoomManager.create_room(@user1, %{name: "Stale Waiting"})
      assert room.status == :waiting

      # Set last_activity to well in the past (beyond idle_waiting_ttl of 600s)
      past = DateTime.add(DateTime.utc_now(), -700, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, past)

      # Trigger startup sweep
      send(GenServer.whereis(RoomManager), :startup_sweep)

      # Synchronize
      _ = RoomManager.list_rooms()

      # Stale waiting room should be removed
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "does not remove fresh :waiting rooms" do
      {:ok, room} = RoomManager.create_room(@user1, %{name: "Fresh Waiting"})
      assert room.status == :waiting

      # Room was just created, last_activity is recent

      # Trigger startup sweep
      send(GenServer.whereis(RoomManager), :startup_sweep)

      # Synchronize
      _ = RoomManager.list_rooms()

      # Fresh waiting room should still exist
      assert {:ok, _} = RoomManager.get_room(room.code)
    end
  end

  # The abandoned sweep (R21) closes a :waiting room with no connected human
  # and no spectators once it has been idle longer than five minutes, or
  # longer than `invited_waiting_ttl_ms` (500 ms in test) while an invite is
  # live. A held seat (a waiting-room disconnect) is not a connected human.
  describe "abandoned sweep with held seats" do
    setup do
      {:ok, room} = RoomManager.create_room(@user1, %{name: "Held Host"})
      :ok = RoomManager.handle_player_disconnect(room.code, @user1)
      {:ok, %{seats: %{north: %{status: :reconnecting}}}} = RoomManager.get_room(room.code)

      %{room: room}
    end

    test "keeps an idle invited room past five minutes until invited_waiting_ttl_ms elapses",
         %{room: room} do
      with_invited_waiting_ttl(:timer.hours(2))

      :ok = RoomManager.note_invite(room.code, DateTime.add(DateTime.utc_now(), 3600, :second))
      idle_for(room.code, 301_000)

      run_sweep()
      assert {:ok, _} = RoomManager.get_room(room.code)

      idle_for(room.code, :timer.hours(2) + 1_000)

      run_sweep()
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "closes an idle invited room after invited_waiting_ttl_ms (test config)", %{room: room} do
      :ok = RoomManager.note_invite(room.code, DateTime.add(DateTime.utc_now(), 3600, :second))
      idle_for(room.code, 1_000)

      run_sweep()
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "falls back to five minutes without a live invite", %{room: room} do
      idle_for(room.code, 1_000)
      run_sweep()
      assert {:ok, _} = RoomManager.get_room(room.code)

      # An expired invite counts as no invite.
      :ok = RoomManager.note_invite(room.code, DateTime.add(DateTime.utc_now(), -1, :second))
      idle_for(room.code, 1_000)
      run_sweep()
      assert {:ok, _} = RoomManager.get_room(room.code)

      idle_for(room.code, 301_000)
      run_sweep()
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "never closes a room with a connected human", %{room: room} do
      {:ok, _, _} = RoomManager.join_room(room.code, @user2)

      idle_for(room.code, 301_000)
      run_sweep()
      assert {:ok, _} = RoomManager.get_room(room.code)

      :ok = RoomManager.note_invite(room.code, DateTime.add(DateTime.utc_now(), 3600, :second))
      idle_for(room.code, 301_000)
      run_sweep()
      assert {:ok, %{seats: %{north: %{status: :reconnecting}}}} = RoomManager.get_room(room.code)
    end

    test "a reclaimed seat keeps the room alive", %{room: room} do
      {:ok, _} = RoomManager.handle_player_reconnect(room.code, @user1)

      idle_for(room.code, 301_000)
      run_sweep()
      assert {:ok, _} = RoomManager.get_room(room.code)
    end
  end

  defp idle_for(room_code, idle_ms) do
    past = DateTime.add(DateTime.utc_now(), -idle_ms, :millisecond)
    :ok = RoomManager.set_last_activity_for_test(room_code, past)
  end

  # Sends the sweep message and synchronizes with the RoomManager afterwards.
  defp run_sweep do
    send(GenServer.whereis(RoomManager), :cleanup_abandoned_rooms)
    _ = RoomManager.list_rooms()
    :ok
  end

  defp with_invited_waiting_ttl(ttl_ms) do
    original = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.put(original, :invited_waiting_ttl_ms, ttl_ms)
    )

    on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
  end

  describe "health check" do
    test "recovers dead substitute controllers instead of clearing their references" do
      room = create_playing_room()

      # Disconnect a player through Phase 2 (bot spawns)
      :ok = RoomManager.handle_player_disconnect(room.code, @user2)
      {:ok, disc_room} = RoomManager.get_room(room.code)
      position = position_for(disc_room, @user2)

      {:ok, phase2_room} = RoomManagerCase.expire_phase(room.code, position, :phase2_start)

      bot_pid = phase2_room.seats[position].bot_pid
      assert bot_pid != nil
      assert Process.alive?(bot_pid)

      # Kill the bot process manually (simulating a crash)
      Process.exit(bot_pid, :kill)
      Process.sleep(50)
      refute Process.alive?(bot_pid)

      # Trigger health check
      send(GenServer.whereis(RoomManager), :health_check)

      # Synchronize
      _ = RoomManager.list_rooms()

      # DOWN recovery and health reconciliation must converge on one live PID.
      {:ok, checked_room} = RoomManager.get_room(room.code)
      replacement = checked_room.seats[position].bot_pid
      assert is_pid(replacement)
      assert replacement != bot_pid
      assert Process.alive?(replacement)

      send(GenServer.whereis(RoomManager), {:DOWN, make_ref(), :process, bot_pid, :killed})
      send(GenServer.whereis(RoomManager), :health_check)
      {:ok, checked_again} = RoomManager.get_room(room.code)
      assert checked_again.seats[position].bot_pid == replacement
    end

    test "a lasting problem warns once, and again only after it went away and came back" do
      room = create_playing_room()

      sweep = fn ->
        send(GenServer.whereis(RoomManager), :health_check)
        _ = RoomManager.list_rooms()
      end

      warnings = fn log ->
        length(String.split(log, "room #{room.code} has no game process")) - 1
      end

      # The problem starts inside the capture, so a scheduled sweep cannot log it outside.
      assert 1 ==
               warnings.(
                 ExUnit.CaptureLog.capture_log(fn ->
                   :ok = PidroServer.Games.GameSupervisor.stop_game(room.code)
                   for _ <- 1..3, do: sweep.()
                 end)
               )

      participants = PidroServer.GameArchive.participants(room.seats)

      {:ok, _pid} =
        PidroServer.Games.GameSupervisor.start_game(
          room.code,
          room.config.rule_set,
          room.pace,
          participants
        )

      assert 0 == warnings.(ExUnit.CaptureLog.capture_log(sweep))

      assert 1 ==
               warnings.(
                 ExUnit.CaptureLog.capture_log(fn ->
                   :ok = PidroServer.Games.GameSupervisor.stop_game(room.code)
                   for _ <- 1..2, do: sweep.()
                 end)
               )
    end
  end
end
