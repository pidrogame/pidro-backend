defmodule PidroServer.Games.Bots.BotManagerTest do
  @moduledoc """
  Tests for BotManager seat-skipping and cascading cleanup.

  Covers:
  - start_bots skips occupied seats
  - start_bots returns {:error, :not_enough_seats} when insufficient empty seats
  - After stop_all_bots, list_bots returns empty map
  """

  use ExUnit.Case, async: false

  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.Bots.BotPlayer
  alias PidroServer.Games.Bots.SubstituteBot
  alias PidroServer.Games.RoomManager

  # async: false required because RoomManager and BotManager are singleton GenServers

  setup do
    # Ensure RoomManager is running and reset between tests
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    PidroServer.RoomManagerCase.cleanup()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    # Ensure BotSupervisor is running
    case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
      nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
      _pid -> :ok
    end

    # Ensure BotManager is running
    case GenServer.whereis(BotManager) do
      nil -> start_supervised!(BotManager)
      _pid -> :ok
    end

    :ok
  end

  # Helper: stop all bots for a room to clean up after tests
  defp cleanup_bots(room_code) do
    BotManager.stop_all_bots(room_code)
  end

  describe "start_bots/4 skips occupied seats" do
    test "host at north, request 3 bots — bots placed at east/south/west" do
      {:ok, room} = RoomManager.create_room("host_user", %{})
      room_code = room.code

      # Host is at north; request 3 bots for the remaining seats
      {:ok, pids} = BotManager.start_bots(room_code, 3, :random, 0)

      assert length(pids) == 3
      assert Enum.all?(pids, &is_pid/1)

      # Verify bots are at east, south, west — NOT north
      bots = BotManager.list_bots(room_code)
      assert map_size(bots) == 3
      assert Map.has_key?(bots, :east)
      assert Map.has_key?(bots, :south)
      assert Map.has_key?(bots, :west)
      refute Map.has_key?(bots, :north)

      cleanup_bots(room_code)
    end

    test "host at north + player at east, request 2 bots — bots at south/west" do
      {:ok, room} = RoomManager.create_room("host_user", %{})
      room_code = room.code

      # Add a second human at east
      {:ok, _room, :east} = RoomManager.join_room(room_code, "player2", :east)

      # Request 2 bots — should fill south and west
      {:ok, pids} = BotManager.start_bots(room_code, 2, :random, 0)

      assert length(pids) == 2

      bots = BotManager.list_bots(room_code)
      assert map_size(bots) == 2
      assert Map.has_key?(bots, :south)
      assert Map.has_key?(bots, :west)

      cleanup_bots(room_code)
    end

    test "request 1 bot with 1 empty seat — fills the only available seat" do
      {:ok, room} = RoomManager.create_room("host_user", %{})
      room_code = room.code

      {:ok, _, _} = RoomManager.join_room(room_code, "player2", :east)
      {:ok, _, _} = RoomManager.join_room(room_code, "player3", :south)

      # Only west is empty
      {:ok, pids} = BotManager.start_bots(room_code, 1, :random, 0)

      assert length(pids) == 1

      bots = BotManager.list_bots(room_code)
      assert map_size(bots) == 1
      assert Map.has_key?(bots, :west)

      cleanup_bots(room_code)
    end
  end

  describe "pacing policy" do
    test "start_bot/3 uses runtime pacing with no fixed override" do
      {:ok, room} = RoomManager.create_room("host_user", %{})

      {:ok, pid} = BotManager.start_bot(room.code, :east, :random)

      assert :sys.get_state(pid).delay_ms_override == nil

      cleanup_bots(room.code)
    end

    test "start_bot/4 keeps an explicit fixed delay override for dev callers" do
      {:ok, room} = RoomManager.create_room("host_user", %{})

      {:ok, pid} = BotManager.start_bot(room.code, :east, :random, 0)

      assert :sys.get_state(pid).delay_ms_override == 0

      cleanup_bots(room.code)
    end
  end

  describe "game PubSub resilience" do
    test "bot stays alive when the post-game progression summary is broadcast" do
      {:ok, room} = RoomManager.create_room("host_user", %{})

      pid =
        start_supervised!(
          {BotPlayer, room_code: room.code, position: :east, strategy: :random, delay_ms: 0},
          restart: :temporary
        )

      ref = Process.monitor(pid)

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room.code}",
        {:progression_summary, room.code, %{"host_user" => %{xp_delta: 10}}}
      )

      refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100
      assert Process.alive?(pid)
    end

    test "substitute bot stays alive when the post-game progression summary is broadcast" do
      {:ok, room} = RoomManager.create_room("host_user", %{})

      pid =
        start_supervised!(
          {SubstituteBot, room_code: room.code, position: :east},
          restart: :temporary
        )

      ref = Process.monitor(pid)

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room.code}",
        {:progression_summary, room.code, %{"host_user" => %{xp_delta: 10}}}
      )

      refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100
      assert Process.alive?(pid)
    end
  end

  describe "start_bots/4 returns error when not enough seats" do
    test "host at north, request 4 bots — only 3 seats available" do
      {:ok, room} = RoomManager.create_room("host_user", %{})

      assert {:error, :not_enough_seats} =
               BotManager.start_bots(room.code, 4, :random, 0)

      # Verify no bots were started
      bots = BotManager.list_bots(room.code)
      assert bots == %{}
    end

    test "3 seats occupied, request 2 bots — only 1 seat available" do
      {:ok, room} = RoomManager.create_room("host_user", %{})
      room_code = room.code

      {:ok, _, _} = RoomManager.join_room(room_code, "player2", :east)
      {:ok, _, _} = RoomManager.join_room(room_code, "player3", :south)

      # Only west is empty, but we request 2
      assert {:error, :not_enough_seats} =
               BotManager.start_bots(room_code, 2, :random, 0)

      # Verify no bots were started
      bots = BotManager.list_bots(room_code)
      assert bots == %{}
    end
  end

  describe "cascading cleanup — stop_all_bots clears bot state" do
    test "after stop_all_bots, list_bots returns empty map" do
      {:ok, room} = RoomManager.create_room("host_user", %{})
      room_code = room.code

      {:ok, _pids} = BotManager.start_bots(room_code, 3, :random, 0)

      # Verify bots exist
      bots_before = BotManager.list_bots(room_code)
      assert map_size(bots_before) == 3

      # Stop all bots (mimicking cascading cleanup on room deletion)
      :ok = BotManager.stop_all_bots(room_code)

      # Verify bots are cleared
      bots_after = BotManager.list_bots(room_code)
      assert bots_after == %{}
    end

    test "stop_all_bots on room with no bots returns :ok" do
      {:ok, room} = RoomManager.create_room("host_user", %{})

      assert :ok = BotManager.stop_all_bots(room.code)
      assert BotManager.list_bots(room.code) == %{}
    end

    test "stop_all_bots terminates bot processes" do
      {:ok, room} = RoomManager.create_room("host_user", %{})
      room_code = room.code

      {:ok, pids} = BotManager.start_bots(room_code, 3, :random, 0)

      # All pids should be alive
      assert Enum.all?(pids, &Process.alive?/1)

      :ok = BotManager.stop_all_bots(room_code)

      # Give processes time to terminate
      Process.sleep(50)

      # All pids should be dead
      refute Enum.any?(pids, &Process.alive?/1)
    end

    test "full cascading cleanup: stop bots then close room" do
      {:ok, room} = RoomManager.create_room("host_user", %{})
      room_code = room.code

      {:ok, _pids} = BotManager.start_bots(room_code, 3, :random, 0)

      # Cascading cleanup (same pattern as GameListLive.handle_single_delete)
      BotManager.stop_all_bots(room_code)
      :ok = RoomManager.close_room(room_code)

      # Verify both bots and room are gone
      assert BotManager.list_bots(room_code) == %{}
      assert {:error, :room_not_found} = RoomManager.get_room(room_code)
    end
  end
end
