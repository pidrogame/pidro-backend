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

      assert seat_events(user) == [{"drop", nil}, {"return", nil}]
    end

    test "a player gone past the grace period has a drop and no return" do
      {room, user} = bidding_room()
      position = position_of(room, user)

      assert :ok = RoomManager.handle_player_disconnect(room.code, user)
      expire_phase(room.code, position, :phase2_start)
      expire_phase(room.code, position, :phase3_gone)

      assert {:error, :seat_permanently_filled} =
               RoomManager.handle_player_reconnect(room.code, user)

      assert seat_events(user) == [{"drop", nil}]
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
