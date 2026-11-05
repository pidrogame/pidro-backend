defmodule PidroServerWeb.ReadinessChannelTest do
  use PidroServerWeb.ChannelCase, async: false

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.{GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Games.Bots.BotManager
  alias PidroServerWeb.GameChannel

  setup do
    Process.flag(:trap_exit, true)
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    users = Enum.map(1..4, &AccountsFixtures.user_fixture(%{display_name: "Ready Player #{&1}"}))
    [host | others] = users
    {:ok, room} = RoomManager.create_room(host.id, %{})
    for user <- others, do: RoomManager.join_room(room.code, user.id)

    # Deliberately withhold the fourth channel join: filling the room via HTTP
    # must not start a game while the slow final client is still connecting.
    channels =
      Enum.map(Enum.take(users, 3), fn user ->
        {:ok, socket} = create_socket(user)
        {:ok, reply, joined} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")
        {user, reply, joined}
      end)

    %{room: room, channels: channels, last_user: List.last(users)}
  end

  test "late fourth join and staggered confirmations share named snapshots and start only on final ready",
       %{
         room: room,
         channels: channels,
         last_user: last_user
       } do
    [{host, %{readiness: initial} = reply, socket} | rest] = channels
    refute Map.has_key?(reply, :state)
    assert initial.status == :waiting
    assert initial.ready_players == []
    assert initial.room_id == room.id
    assert initial.seats.north.username == host.username
    assert initial.seats.north.display_name == host.display_name
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)

    {:ok, last_socket} = create_socket(last_user)

    {:ok, last_reply, last_joined} =
      subscribe_and_join(last_socket, GameChannel, "game:#{room.code}")

    assert last_reply.readiness == initial
    refute Map.has_key?(last_reply, :state)
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)

    ref = push(socket, "ready", %{})

    assert_reply ref, :error, %{
      reason: "invalid_readiness",
      error_code: "invalid_readiness",
      error_params: %{}
    }

    ref = push(socket, "ready", %{"room_id" => "old-room", "ready_epoch" => initial.ready_epoch})

    assert_reply ref, :error, %{
      reason: "stale_readiness",
      readiness: ^initial,
      error_code: "stale_readiness",
      error_params: %{}
    }

    params = %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch}
    ref = push(socket, "ready", params)
    assert_reply ref, :ok, %{readiness: accepted}
    assert accepted.ready_epoch == initial.ready_epoch
    assert accepted.snapshot_revision == initial.snapshot_revision + 1
    assert accepted.ready_players == [:north]
    assert accepted.seats == initial.seats
    assert_push "readiness_updated", ^accepted

    ref = push(socket, "ready", params)
    assert_reply ref, :ok, success
    assert success == %{readiness: accepted}
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)

    Enum.each(rest ++ [{last_user, last_reply, last_joined}], fn {_user, _reply, joined} ->
      assert {:error, :not_found} = GameSupervisor.get_game(room.code)
      ref = push(joined, "ready", params)
      assert_reply ref, :ok, %{readiness: %{ready_epoch: epoch}}
      assert epoch == initial.ready_epoch
    end)

    assert {:ok, %{status: :playing}} = RoomManager.get_room(room.code)
    assert {:ok, pid} = GameSupervisor.get_game(room.code)
    ref = push(socket, "ready", params)
    assert_reply ref, :ok, %{readiness: %{status: :playing}}
    assert {:ok, ^pid} = GameSupervisor.get_game(room.code)
  end

  describe "waiting table connection loss" do
    setup do
      original = Application.get_env(:pidro_server, Lifecycle)

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.put(original, :waiting_disconnect_timeout_ms, 400)
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
      :ok
    end

    test "ZIB3: a lost connection frees the seat and a replacement can start with four fresh readies",
         %{room: room, channels: channels, last_user: last_user} do
      [{_host, %{readiness: initial}, host_socket}, {away, _, away_socket}, third] = channels
      {:ok, socket} = create_socket(last_user)
      {:ok, _, fourth_socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")
      params = %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch}
      ref = push(host_socket, "ready", params)
      assert_reply ref, :ok, %{readiness: %{ready_players: [:north]}}

      close(away_socket)
      assert_push "player_disconnected", %{user_id: away_id, reason: "connection_lost"}
      assert away_id == away.id
      assert_push "readiness_updated", %{seats: %{east: %{status: :reconnecting}}} = dropped
      assert dropped.room_id == initial.room_id
      assert dropped.snapshot_revision > initial.snapshot_revision
      {:ok, held} = RoomManager.get_room(room.code)
      assert held.seats.east.status == :reconnecting
      assert held.positions.east == away.id
      assert Enum.count(held.positions, fn {_, id} -> id != nil end) == 4
      Process.sleep(150)
      assert {:ok, ^held} = RoomManager.get_room(room.code)
      params = %{"room_id" => room.id, "ready_epoch" => held.ready_epoch}
      {_, _, third_socket} = third

      for socket <- [host_socket, third_socket, fourth_socket] do
        ref = push(socket, "ready", params)
        assert_reply ref, :error, %{reason: "table_not_full"}
      end

      assert_push "readiness_updated",
                  %{
                    seats: %{east: %{occupant_type: :vacant, status: nil, user_id: nil}},
                    positions: %{east: nil}
                  } =
                    expired,
                  1_500

      assert expired.room_id == dropped.room_id
      assert expired.snapshot_revision > dropped.snapshot_revision
      assert expired.ready_players == []
      {:ok, open} = RoomManager.get_room(room.code)
      assert open.status == :waiting
      assert open.positions.east == nil
      assert Enum.count(open.positions, fn {_, id} -> id != nil end) == 3
      assert open.ready_player_ids == MapSet.new()
      assert open.ready_epoch > held.ready_epoch
      assert {:error, :not_found} = GameSupervisor.get_game(room.code)

      replacement = AccountsFixtures.user_fixture(%{display_name: "Replacement"})
      assert {:ok, _, :east} = RoomManager.join_room(room.code, replacement.id)
      {:ok, socket} = create_socket(replacement)

      {:ok, %{readiness: current}, replacement_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      assert current.ready_players == []
      params = %{"room_id" => room.id, "ready_epoch" => current.ready_epoch}

      for socket <- [host_socket, third_socket, fourth_socket, replacement_socket] do
        assert {:error, :not_found} = GameSupervisor.get_game(room.code)
        ref = push(socket, "ready", params)
        assert_reply ref, :ok, %{}
      end

      assert {:ok, %{status: :playing}} = RoomManager.get_room(room.code)
      assert {:ok, _pid} = GameSupervisor.get_game(room.code)
    end

    test "return inside the window keeps the same seat past the old deadline",
         %{room: room, channels: [_, {away, _, socket} | _]} do
      close(socket)
      {:ok, held} = RoomManager.get_room(room.code)
      assert held.seats.east.status == :reconnecting
      assert_push "readiness_updated", %{seats: %{east: %{status: :reconnecting}}} = dropped
      {:ok, socket} = create_socket(away)
      assert {:ok, _, _} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")
      assert_push "readiness_updated", %{seats: %{east: %{status: :connected}}} = reconnected
      assert reconnected.room_id == dropped.room_id
      assert reconnected.snapshot_revision > dropped.snapshot_revision
      assert reconnected.ready_epoch == dropped.ready_epoch
      {:ok, returned} = RoomManager.get_room(room.code)

      Process.sleep(500)
      assert {:ok, ^returned} = RoomManager.get_room(room.code)
      assert returned.positions == held.positions
      assert returned.seats.east.status == :connected
      assert returned.ready_epoch == held.ready_epoch
    end

    test "a host lost past the window closes the waiting table",
         %{room: room, channels: [{_, _, socket} | _]} do
      close(socket)

      assert {:ok, %{seats: %{north: %{status: :reconnecting}}}} =
               RoomManager.get_room(room.code)

      Process.sleep(500)
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    for solo <- [true, false] do
      test "one human with three bots holds the waiting seat without a deadline (solo: #{solo})",
           %{channels: channels} do
        for {_, _, socket} <- channels, do: close(socket)
        RoomManager.reset_for_test()
        user = AccountsFixtures.user_fixture()
        {:ok, room} = RoomManager.create_room(user.id, %{solo: unquote(solo)})

        for position <- [:east, :south, :west] do
          assert {:ok, _} = BotManager.start_bot(room.code, position, :basic)
        end

        {:ok, socket} = create_socket(user)
        {:ok, _, socket} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")
        close(socket)
        {:ok, held} = RoomManager.get_room(room.code)
        assert held.status == :waiting
        assert held.seats.north.status == :reconnecting

        Process.sleep(500)
        assert {:ok, ^held} = RoomManager.get_room(room.code)
        assert held.phase_timers == %{}
      end
    end
  end

  test "late player joins at the authoritative snapshot position after a seat move", %{
    room: room,
    channels: [{host, _, _}, {second, _, departed} | _],
    last_user: last_user
  } do
    assert :ok = RoomManager.leave_room(second.id)
    departed_pid = departed.channel_pid
    assert_receive {:EXIT, ^departed_pid, {:shutdown, :left}}
    assert {:ok, _} = RoomManager.move_seat(room.code, host.id, last_user.id, :east)
    {:ok, socket} = create_socket(last_user)
    assert {:ok, reply, joined} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")
    assert reply.position == :east
    assert reply.readiness.positions.east == last_user.id
    assert :sys.get_state(joined.channel_pid).assigns.position == :east

    {:ok, removed_socket} = create_socket(second)
    assert {:error, _} = subscribe_and_join(removed_socket, GameChannel, "game:#{room.code}")
  end

  test "ready after room closure omits readiness instead of inventing an incomplete roster", %{
    room: room,
    channels: [{_host, %{readiness: initial}, socket} | _]
  } do
    assert :ok = RoomManager.close_room(room.code)
    ref = push(socket, "ready", %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch})
    assert_reply ref, :error, response

    assert response == %{
             reason: "room_not_found",
             error_code: "room_not_found",
             error_params: %{}
           }
  end

  test "rematch errors preserve the readiness snapshot and malformed payload reason", %{
    room: room,
    channels: [{_host, %{readiness: initial}, socket} | _]
  } do
    ref = push(socket, "rematch", %{})
    assert_reply ref, :error, response

    assert response == %{
             reason: "invalid_readiness",
             error_code: "invalid_readiness",
             error_params: %{}
           }

    ref = push(socket, "rematch", %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch})
    assert_reply ref, :error, response

    assert response == %{
             reason: "room_not_finished",
             readiness: initial,
             error_code: "room_not_finished",
             error_params: %{}
           }
  end

  test "roster replacement rejects old intent with the current full snapshot", %{
    room: room,
    channels: channels
  } do
    [{host, %{readiness: initial}, socket}, {second, _, departed} | _] = channels
    params = %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch}
    ref = push(socket, "ready", params)
    assert_reply ref, :ok, %{}
    assert :ok = RoomManager.leave_room(second.id)
    departed_pid = departed.channel_pid
    assert_receive {:EXIT, ^departed_pid, {:shutdown, :left}}
    replacement = AccountsFixtures.user_fixture(%{display_name: "Replacement"})
    {:ok, _, :east} = RoomManager.join_room(room.code, replacement.id)

    ref = push(socket, "ready", params)
    assert_reply ref, :error, %{reason: "stale_readiness", readiness: current}
    assert current.ready_epoch > initial.ready_epoch
    assert current.ready_players == []
    assert current.positions.north == host.id
    assert current.positions.east == replacement.id
    assert current.seats.east.display_name == "Replacement"
    assert_push "readiness_updated", ^current
    assert {:error, :not_found} = GameSupervisor.get_game(room.code)
  end
end
