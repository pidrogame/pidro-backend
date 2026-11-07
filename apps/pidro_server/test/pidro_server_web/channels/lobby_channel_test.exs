defmodule PidroServerWeb.LobbyChannelTest do
  @moduledoc """
  Integration tests for LobbyChannel - Phase 4: Real-time Gameplay

  Tests the lobby channel functionality:
  - Joining the lobby
  - Receiving current room list
  - Receiving real-time room updates
  - Presence tracking in lobby
  """

  use PidroServerWeb.ChannelCase, async: false

  alias PidroServer.Accounts
  alias PidroServer.Games.RoomManager
  alias PidroServerWeb.API.RoomJSON
  alias PidroServerWeb.LobbyChannel

  @moduletag :channel

  setup do
    # Create a test user
    {:ok, user} =
      Accounts.Auth.register_user(%{
        username: "lobby_user",
        email: "lobby@test.com",
        password: "password123"
      })

    {:ok, socket} = create_socket(user)

    %{user: user, socket: socket}
  end

  test "friends_changed reaches both affected lobbies, never an unrelated lobby", %{user: user} do
    friend = PidroServer.AccountsFixtures.user_fixture()
    stranger = PidroServer.AccountsFixtures.user_fixture()

    sockets =
      for account <- [user, friend, stranger] do
        {:ok, socket} = create_socket(account)
        {:ok, _, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
        socket
      end

    [a, b, unrelated] = sockets

    for _ <- sockets, do: assert_push("presence_state", _)

    for {operation, expected} <- [
          {&PidroServer.Friends.add/2, [%{user_id: user.id, presence: "online"}]},
          {&PidroServer.Friends.remove/2, []}
        ] do
      assert {:ok, _} = operation.(user.id, friend.id)

      assert Enum.map(
               PidroServer.Friends.list(friend.id).added_you,
               &Map.take(&1, [:user_id, :presence])
             ) == expected

      a_ref = a.join_ref
      b_ref = b.join_ref
      unrelated_ref = unrelated.join_ref

      assert_receive %Phoenix.Socket.Message{
        event: "friends_changed",
        payload: %{},
        join_ref: ^a_ref
      }

      assert_receive %Phoenix.Socket.Message{
        event: "friends_changed",
        payload: %{},
        join_ref: ^b_ref
      }

      refute_receive %Phoenix.Socket.Message{event: "friends_changed", join_ref: ^unrelated_ref}
    end
  end

  test "join exposes optional store minimums without requiring a client upgrade", %{
    socket: socket
  } do
    old = Application.get_env(:pidro_server, :minimum_native_versions, %{})
    old_urls = Application.get_env(:pidro_server, :native_store_urls, %{})

    on_exit(fn ->
      Application.put_env(:pidro_server, :minimum_native_versions, old)
      Application.put_env(:pidro_server, :native_store_urls, old_urls)
    end)

    Application.put_env(:pidro_server, :minimum_native_versions, %{"android" => "3.2.4"})
    urls = %{"android" => "https://example.test/android", "ios" => "https://example.test/ios"}
    Application.put_env(:pidro_server, :native_store_urls, urls)

    assert {:ok, %{minimum_native_versions: %{"android" => "3.2.4"}, native_store_urls: ^urls}, _} =
             subscribe_and_join(socket, LobbyChannel, "lobby", %{})

    Application.put_env(:pidro_server, :native_store_urls, %{})

    assert {:ok, %{minimum_native_versions: %{"android" => "3.2.4"}, native_store_urls: missing},
            _} =
             subscribe_and_join(socket, LobbyChannel, "lobby", %{})

    assert missing == %{}
    Application.put_env(:pidro_server, :minimum_native_versions, %{})

    assert {:ok, %{minimum_native_versions: empty}, _} =
             subscribe_and_join(socket, LobbyChannel, "lobby", %{})

    assert empty == %{}

    alias PidroServer.News

    {:ok, older} =
      News.create(%{
        title_en: "Older update",
        body_en: "x",
        app_update: true,
        show_below_android: "3.2.5",
        show_below_ios: "3.2.4"
      })

    {:ok, _} = News.publish(older)

    {:ok, latest} =
      News.create(%{
        title_en: "New update",
        body_en: "x",
        app_update: true,
        show_as_popup: true,
        show_below_android: "3.2.6"
      })

    {:ok, latest} = News.publish(latest)

    {:ok, _draft} =
      News.create(%{
        title_en: "Not live",
        body_en: "x",
        app_update: true,
        show_below_ios: "9.0.0"
      })

    Application.put_env(:pidro_server, :minimum_native_versions, %{"ios" => "8.0.0"})

    assert {:ok,
            %{
              minimum_native_versions: %{"android" => "3.2.6"} = minimums,
              native_update_popup: true
            }, _} =
             subscribe_and_join(socket, LobbyChannel, "lobby", %{})

    refute Map.has_key?(minimums, "ios")

    {:ok, _} = News.update(latest, %{show_as_popup: false, show_below_android: ""})

    assert {:ok, %{minimum_native_versions: empty, native_update_popup: false}, _} =
             subscribe_and_join(socket, LobbyChannel, "lobby", %{})

    assert empty == %{}
  end

  test "a request reaches only its receiver's lobby, and its acceptance only the sender's",
       %{user: user} do
    friend = PidroServer.AccountsFixtures.user_fixture(%{display_name: "Nora"})
    stranger = PidroServer.AccountsFixtures.user_fixture()

    [a, b, _] =
      for account <- [user, friend, stranger] do
        {:ok, socket} = create_socket(account)
        {:ok, _, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
        assert_push("presence_state", _)
        socket.join_ref
      end

    user_id = user.id
    friend_id = friend.id
    {:ok, _} = PidroServer.Friends.add(user.id, friend.id)

    assert_receive %Phoenix.Socket.Message{
      event: "friend_request",
      payload: %{player: %{user_id: ^user_id, presence: "online"}, played_together_at: nil},
      join_ref: ^b
    }

    {:ok, _} = PidroServer.Friends.add(friend.id, user.id)

    assert_receive %Phoenix.Socket.Message{
      event: "friend_accepted",
      payload: %{player: %{user_id: ^friend_id, display_name: "Nora"}, source: "accept"},
      join_ref: ^a
    }

    refute_receive %Phoenix.Socket.Message{event: "friend_" <> _}
  end

  test "lobby snapshots and updates expose holds and channel joins honor them", %{
    socket: socket,
    user: user
  } do
    host = PidroServer.AccountsFixtures.user_fixture()
    friend = PidroServer.AccountsFixtures.user_fixture(%{display_name: "Nora"})
    {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{south: friend.id}})
    {:ok, reply, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
    listed = Enum.find(reply.lobby.open_tables, &(&1.code == room.code))
    assert listed.available_positions == [:east, :west]
    held = Enum.find(listed.seats, &(&1.position == :south))
    assert held.status == "free"
    assert held.held_for == %{user_id: friend.id, display_name: "Nora", avatar_url: nil}
    ref = push(socket, "join_room", %{code: room.code, position: "south"})
    assert_reply ref, :error, %{reason: "seat_taken"}

    {:ok, _} = RoomManager.set_seat_hold(room.code, host.id, :south, user.id)
    assert_push "room_updated", %{room: updated}
    assert Enum.find(updated.seats, &(&1.position == :south)).held_for.user_id == user.id
    ref = push(socket, "join_room", %{code: room.code, position: "south"})
    assert_reply ref, :ok, %{assigned_position: :south, room: joined}
    refute Map.has_key?(Enum.find(joined.seats, &(&1.position == :south)), :held_for)
    RoomManager.close_room(room.code)
  end

  test "with watching tables off, the lobby lists and pushes no table to watch", %{
    socket: socket
  } do
    on_exit(fn -> Application.put_env(:pidro_server, :watching_tables, true) end)
    Application.put_env(:pidro_server, :watching_tables, false)

    [host | others] = Enum.map(1..4, fn _ -> PidroServer.AccountsFixtures.user_fixture() end)
    {:ok, room} = RoomManager.create_room(host.id)
    for player <- others, do: {:ok, _, _} = RoomManager.join_room(room.code, player.id)
    PidroServer.RoomFixtures.ready_room(room.code)

    {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
    assert reply.lobby.spectatable == []
    refute room.code in Enum.map(Enum.concat(Map.values(reply.lobby)), & &1.code)

    :ok = RoomManager.handle_player_disconnect(room.code, hd(others).id)
    assert_push "room_updated", %{room: %{code: code}, category: nil}
    assert code == room.code

    Application.put_env(:pidro_server, :watching_tables, true)
    {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
    assert [%{code: ^code}] = reply.lobby.spectatable
    :ok = RoomManager.handle_player_disconnect(room.code, List.last(others).id)
    assert_push "room_updated", %{room: %{code: ^code}, category: "spectatable"}
    RoomManager.close_room(room.code)
  end

  test "seat invitations reach every invited lobby only, from create through release and seating",
       %{user: host} do
    friend = PidroServer.AccountsFixtures.user_fixture()
    stranger = PidroServer.AccountsFixtures.user_fixture()

    [host_ref, friend_ref, other_friend_ref, stranger_ref] =
      for account <- [host, friend, friend, stranger] do
        {:ok, socket} = create_socket(account)
        {:ok, _, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
        assert_push "presence_state", _
        socket.join_ref
      end

    {:ok, room} =
      RoomManager.create_room(host.id, %{
        rule_set: :louisiana,
        seat_holds: %{south: friend.id}
      })

    code = room.code

    expected = %{
      code: code,
      position: :south,
      host_id: host.id,
      host: %{user_id: host.id, display_name: host.username, avatar_url: nil},
      rule_set: "louisiana",
      held_since: DateTime.to_iso8601(room.created_at),
      join_as: "partner"
    }

    for ref <- [friend_ref, other_friend_ref] do
      assert_receive %Phoenix.Socket.Message{
        event: "seat_invitation",
        payload: ^expected,
        join_ref: ^ref
      }
    end

    assert RoomManager.seat_invitations(friend.id) == [expected]
    {:ok, _} = RoomManager.set_seat_hold(code, host.id, :south, friend.id)
    assert RoomManager.seat_invitations(friend.id) == [expected]
    refute_receive %Phoenix.Socket.Message{event: "seat_invitation"}

    {:ok, _} = RoomManager.set_seat_hold(code, host.id, :south, nil)

    for ref <- [friend_ref, other_friend_ref] do
      assert_receive %Phoenix.Socket.Message{
        event: "seat_invitation_gone",
        payload: %{code: ^code, position: :south, reason: "released"},
        join_ref: ^ref
      }
    end

    {:ok, _} = RoomManager.set_seat_hold(code, host.id, :east, friend.id)

    for ref <- [friend_ref, other_friend_ref] do
      assert_receive %Phoenix.Socket.Message{
        event: "seat_invitation",
        payload: %{code: ^code, position: :east, held_since: held_since} = invitation,
        join_ref: ^ref
      }

      assert Map.drop(invitation, [:position, :held_since, :join_as]) ==
               Map.drop(expected, [:position, :held_since, :join_as])

      assert invitation.join_as == "opponent"

      assert {:ok, time, 0} = DateTime.from_iso8601(held_since)
      assert DateTime.compare(time, room.created_at) == :gt
    end

    {:ok, _, :east} = RoomManager.join_room(code, friend.id, :east)

    for ref <- [friend_ref, other_friend_ref] do
      assert_receive %Phoenix.Socket.Message{
        event: "seat_invitation_gone",
        payload: %{code: ^code, position: :east, reason: "declined"},
        join_ref: ^ref
      }
    end

    for _ <- 1..2 do
      account = PidroServer.AccountsFixtures.user_fixture()
      assert {:ok, _, _} = RoomManager.join_room(code, account.id)
    end

    assert PidroServer.RoomFixtures.ready_room(code).status == :playing
    assert RoomManager.seat_invitations(friend.id) == []
    :ok = RoomManager.close_room(code)

    for ref <- [host_ref, stranger_ref] do
      refute_receive %Phoenix.Socket.Message{event: "seat_invitation", join_ref: ^ref}
      refute_receive %Phoenix.Socket.Message{event: "seat_invitation_gone", join_ref: ^ref}
    end

    refute_receive %Phoenix.Socket.Message{event: "seat_invitation_gone"}
  end

  test "a seat invitation says whether it is the host's partner or an opponent", %{user: host} do
    friends = for _ <- 1..3, do: PidroServer.AccountsFixtures.user_fixture()

    for friend <- friends do
      {:ok, socket} = create_socket(friend)
      {:ok, _, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
      assert_push "presence_state", _
    end

    holds = Map.new(Enum.zip([:east, :south, :west], Enum.map(friends, & &1.id)))
    {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: holds})
    assert room.seats.north.user_id == host.id

    for {position, join_as} <- [east: "opponent", south: "partner", west: "opponent"] do
      assert_receive %Phoenix.Socket.Message{
        event: "seat_invitation",
        payload: %{position: ^position, join_as: ^join_as}
      }
    end

    RoomManager.close_room(room.code)
  end

  test "a host who moves seats re-sends each invitation whose partner or opponent changed",
       %{user: host} do
    [east, south] = for _ <- 1..2, do: PidroServer.AccountsFixtures.user_fixture()

    for friend <- [east, south] do
      {:ok, socket} = create_socket(friend)
      {:ok, _, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
      assert_push "presence_state", _
    end

    {:ok, room} =
      RoomManager.create_room(host.id, %{seat_holds: %{east: east.id, south: south.id}})

    assert_push "seat_invitation", %{position: :east, join_as: "opponent"}
    assert_push "seat_invitation", %{position: :south, join_as: "partner"}

    {:ok, _} = RoomManager.move_seat(room.code, host.id, host.id, :west)
    assert_push "seat_invitation", %{position: :east, join_as: "partner"}
    assert_push "seat_invitation", %{position: :south, join_as: "opponent"}
    refute_push "seat_invitation_gone", _

    # Someone else sitting down changes no invitation's meaning.
    stranger = PidroServer.AccountsFixtures.user_fixture()
    {:ok, _, :north} = RoomManager.join_room(room.code, stranger.id, :north)
    refute_push "seat_invitation", _

    RoomManager.close_room(room.code)
  end

  test "replacement, room start and host departure remove invitations", %{user: host} do
    friends = for _ <- 1..2, do: PidroServer.AccountsFixtures.user_fixture()
    [first, second] = friends

    [first_ref, second_ref] =
      for friend <- friends do
        {:ok, socket} = create_socket(friend)
        {:ok, _, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
        assert_push "presence_state", _
        socket.join_ref
      end

    {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{west: first.id}})
    code = room.code
    assert_push "seat_invitation", %{code: ^code, position: :west}
    {:ok, _} = RoomManager.set_seat_hold(code, host.id, :west, second.id)

    assert_receive %Phoenix.Socket.Message{
      event: "seat_invitation_gone",
      payload: %{code: ^code, position: :west, reason: "released"},
      join_ref: ^first_ref
    }

    assert_receive %Phoenix.Socket.Message{
      event: "seat_invitation",
      payload: %{code: ^code, position: :west},
      join_ref: ^second_ref
    }

    :ok = RoomManager.update_room_status(code, :playing)
    assert_push "seat_invitation_gone", %{code: ^code, position: :west, reason: "started"}
    assert RoomManager.seat_invitations(second.id) == []
    :ok = RoomManager.close_room(code)
    refute_push "seat_invitation_gone", _

    {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{east: first.id}})
    code = room.code
    assert_push "seat_invitation", %{code: ^code, position: :east}
    :ok = RoomManager.leave_room(host.id)
    assert_push "seat_invitation_gone", %{code: ^code, position: :east, reason: "closed"}
    assert RoomManager.seat_invitations(first.id) == []

    {:ok, room} =
      RoomManager.create_room(host.id, %{seat_holds: %{south: first.id, west: second.id}})

    code = room.code
    assert_push "seat_invitation", %{code: ^code, position: :south}
    assert_push "seat_invitation", %{code: ^code, position: :west}
    :ok = RoomManager.close_room(code)

    assert_receive %Phoenix.Socket.Message{
      event: "seat_invitation_gone",
      payload: %{code: ^code, position: :south, reason: "closed"},
      join_ref: ^first_ref
    }

    assert_receive %Phoenix.Socket.Message{
      event: "seat_invitation_gone",
      payload: %{code: ^code, position: :west},
      join_ref: ^second_ref
    }
  end

  test "declining, or sitting down with people elsewhere, opens the seat and tells the host", %{
    user: host
  } do
    friend = PidroServer.AccountsFixtures.user_fixture(%{display_name: "Maija"})
    stranger = PidroServer.AccountsFixtures.user_fixture()

    {:ok, socket} = create_socket(friend)
    {:ok, _, lobby} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
    assert_push "presence_state", _

    {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{south: friend.id}})
    code = room.code
    {:ok, socket} = create_socket(host)
    {:ok, _, table} = subscribe_and_join(socket, PidroServerWeb.GameChannel, "game:#{code}", %{})
    assert_push "seat_invitation", %{code: ^code, position: :south}

    assert {:error, :invitation_gone} = RoomManager.decline_seat_hold(code, stranger.id, :south)
    assert {:error, :invitation_gone} = RoomManager.decline_seat_hold(code, friend.id, :east)

    assert {:ok, declined} =
             RoomManager.decline_seat_hold(String.downcase(code), friend.id, :south)

    assert declined.config.seat_holds == %{}
    assert :south in PidroServer.Games.Room.Positions.available(declined)

    maija = %{user_id: friend.id, display_name: "Maija", avatar_url: nil}
    table_ref = table.join_ref
    lobby_ref = lobby.join_ref

    assert_receive %Phoenix.Socket.Message{
      event: "seat_invitation_declined",
      payload: %{position: :south, user: ^maija, reason: "not_now"},
      join_ref: ^table_ref
    }

    assert_receive %Phoenix.Socket.Message{
      event: "seat_invitation_gone",
      payload: %{code: ^code, position: :south, reason: "declined"} = gone,
      join_ref: ^lobby_ref
    }

    # An old client reads only code and position.
    assert %{"code" => ^code, "position" => "south"} = Jason.decode!(Jason.encode!(gone))
    assert {:error, :invitation_gone} = RoomManager.decline_seat_hold(code, friend.id, :south)

    {:ok, _} = RoomManager.set_seat_hold(code, host.id, :south, friend.id)
    assert_push "seat_invitation", %{code: ^code, position: :south}

    # Alone, then with bots only: still coming.
    {:ok, own} = RoomManager.create_room(friend.id)
    {:ok, _, :east} = RoomManager.join_bot(own.code, "bot_east", self(), :east)
    assert [%{code: ^code}] = RoomManager.seat_invitations(friend.id)
    :ok = RoomManager.leave_room(friend.id)

    other_host = PidroServer.AccountsFixtures.user_fixture()
    {:ok, elsewhere} = RoomManager.create_room(other_host.id)
    {:ok, _, _} = RoomManager.join_room(elsewhere.code, friend.id)

    assert_receive %Phoenix.Socket.Message{
      event: "seat_invitation_declined",
      payload: %{position: :south, user: ^maija, reason: "sat_elsewhere"},
      join_ref: ^table_ref
    }

    assert_receive %Phoenix.Socket.Message{
      event: "seat_invitation_gone",
      payload: %{code: ^code, position: :south, reason: "declined"},
      join_ref: ^lobby_ref
    }

    assert RoomManager.seat_invitations(friend.id) == []
    {:ok, reopened} = RoomManager.get_room(code)
    assert reopened.config.seat_holds == %{}

    # Sitting with people, they can't be invited away from them at all.
    assert {:error, :already_in_room} =
             RoomManager.set_seat_hold(code, host.id, :south, friend.id)

    assert {:error, :already_in_room} =
             RoomManager.set_seat(code, host.id, :west, {:held, friend.id})

    third_host = PidroServer.AccountsFixtures.user_fixture()

    assert {:error, :already_in_room} =
             RoomManager.create_room(third_host.id, %{seat_holds: %{south: friend.id}})

    refute_push "seat_invitation", _
    assert RoomManager.seat_invitations(friend.id) == []

    # At a table of bots they still can.
    :ok = RoomManager.leave_room(friend.id)
    {:ok, own} = RoomManager.create_room(friend.id)
    {:ok, _, :east} = RoomManager.join_bot(own.code, "bot_east", self(), :east)
    assert {:ok, _} = RoomManager.set_seat_hold(code, host.id, :south, friend.id)
    assert_push "seat_invitation", %{code: ^code, position: :south}
  end

  test "a block committed before queued lobby delivery suppresses the invitation", %{user: host} do
    friend = PidroServer.AccountsFixtures.user_fixture()
    {:ok, socket} = create_socket(friend)
    {:ok, _, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
    assert_push "presence_state", _

    :sys.suspend(socket.channel_pid)

    try do
      {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{south: friend.id}})
      assert {:ok, _} = PidroServer.Blocks.block(friend.id, host.id)
      assert RoomManager.seat_invitations(friend.id) == []

      assert {:error, :user_not_found} =
               RoomManager.set_seat_hold(room.code, host.id, :east, friend.id)
    after
      :sys.resume(socket.channel_pid)
    end

    refute_push "seat_invitation", _
    assert_push "friends_changed", %{}
    :ok = RoomManager.leave_room(host.id)
  end

  test "the lobby marks a password seat without its password, and join_room cannot guess", %{
    socket: socket
  } do
    host = PidroServer.AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{password_seats: [:east]})
    password = room.config.seat_password
    {:ok, reply, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
    listed = Enum.find(reply.lobby.open_tables, &(&1.code == room.code))

    assert Enum.find(listed.seats, &(&1.position == :east)).password
    refute Enum.find(listed.seats, &(&1.position == :west)).password
    refute inspect(reply) =~ "seat_password"

    # The channel takes no password: guesses go through the rate-limited REST join.
    ref = push(socket, "join_room", %{code: room.code, position: "east", password: password})

    assert_reply ref, :error, %{
      reason: "seat_requires_password",
      error_code: "seat_requires_password"
    }
  end

  test "join_room rejects below the bar and accepts the exact combined boundary", %{
    socket: socket,
    user: user
  } do
    host = PidroServer.AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{seat_requirements: %{east: 1000}})
    {:ok, _} = PidroServer.Profiles.import_legacy_progression(user, %{legacy_played_games: 999})
    {:ok, reply, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
    listed = Enum.find(reply.lobby.open_tables, &(&1.code == room.code))
    assert Enum.find(listed.seats, &(&1.position == :east)).min_games == 1000

    ref = push(socket, "join_room", %{code: room.code, position: "east"})

    assert_reply ref, :error, %{
      status: "error",
      reason: "seat_requires_games",
      min_games: 1000,
      games_played: 999,
      error_code: "seat_requires_games",
      error_params: %{min_games: 1000, games_played: 999}
    }

    {:ok, profile} = PidroServer.Profiles.get_or_create_profile(user.id)
    profile |> Ecto.Changeset.change(games_played: 1) |> PidroServer.Repo.update!()
    ref = push(socket, "join_room", %{code: room.code, position: "east"})
    assert_reply ref, :ok, success
    assert %{assigned_position: :east, room: joined} = success
    assert Enum.sort(Map.keys(success)) == [:assigned_position, :room]
    assert Enum.find(joined.seats, &(&1.position == :east)).min_games == 0
    RoomManager.close_room(room.code)
  end

  test "join_room errors preserve status and legacy reason", %{socket: socket} do
    {:ok, reply, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
    refute Map.has_key?(reply, :error_code)
    refute Map.has_key?(reply, :error_params)

    for {params, reason} <- [
          {%{}, "invalid_room_params"},
          {%{"code" => "MISSING"}, "room_not_found"}
        ] do
      ref = push(socket, "join_room", params)
      assert_reply ref, :error, response
      assert response == %{status: "error", reason: reason, error_code: reason, error_params: %{}}
    end
  end

  test "join_room never exposes internal non-atom reasons", %{socket: socket} do
    {:ok, _, socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})
    assert_push "presence_state", _

    failures = [
      {{:unexpected_failure, %{token: "private-token"}}, "action_failed"},
      {%RuntimeError{message: "private diagnostic"}, "action_failed"},
      {{:seat_taken, %{token: "private-token"}}, "seat_taken"}
    ]

    # Substitute only the dependency reply; exercise the real channel transport.
    manager = Process.whereis(RoomManager)

    responder =
      spawn(fn ->
        for {reason, _code} <- failures do
          receive do
            {:"$gen_call", from, {:join_room, "ERROR", _, _, _, _}} ->
              GenServer.reply(from, {:error, reason})
          end
        end

        receive do
          :stop -> :ok
        end
      end)

    Process.unregister(RoomManager)
    Process.register(responder, RoomManager)

    try do
      for {_reason, code} <- failures do
        ref = push(socket, "join_room", %{code: "ERROR"})
        assert_reply ref, :error, response

        assert response == %{
                 status: "error",
                 reason: "action_failed",
                 error_code: code,
                 error_params: %{}
               }
      end
    after
      Process.unregister(RoomManager)
      Process.register(manager, RoomManager)
      Process.exit(responder, :kill)
    end
  end

  describe "join/3" do
    test "authenticated user can join lobby", %{socket: socket} do
      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      assert is_list(rooms)
    end

    test "returns current room list on join", %{socket: socket, user: user} do
      # Create a room first
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Test Room"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      assert is_list(rooms)
      assert length(rooms) >= 1

      # Find our created room
      created_room = Enum.find(rooms, fn r -> r.code == room.code end)
      assert created_room != nil
      assert created_room.host_id == user.id
      assert created_room.player_count == 1
      assert created_room.max_players == 4
      assert created_room.status == :waiting
    end

    test "room list carries the config and no metadata", %{socket: socket, user: user} do
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Epic Game"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      created_room = Enum.find(rooms, fn r -> r.code == room.code end)

      assert created_room.config == %{
               name: "Epic Game",
               bot_difficulty: "basic",
               rule_set: "finnish",
               solo: false
             }

      refute Map.has_key?(created_room, :metadata)
    end

    test "an unknown room attribute is rejected and no room reaches the lobby", %{
      socket: socket,
      user: user
    } do
      assert {:error, {:invalid_room_params, [%{field: "difficulty"}]}} =
               RoomManager.create_room(user.id, %{name: "Epic Game", difficulty: "hard"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      refute Enum.any?(reply.rooms, &(&1.host_id == user.id))
      refute Enum.any?(RoomManager.list_rooms(:all), &(&1.host_id == user.id))
    end

    test "does not return single-player rooms on join", %{socket: socket, user: user} do
      {:ok, solo_room} = RoomManager.create_room(user.id, %{name: "Solo", solo: true})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      refute Enum.any?(rooms, fn room -> room.code == solo_room.code end)
    end
  end

  describe "presence tracking" do
    test "tracks presence when user joins lobby", %{socket: socket} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Should receive presence_state after join
      assert_push "presence_state", _presence_state, 1000
    end
  end

  describe "lobby events" do
    test "broadcasts when new room is created", %{socket: socket, user: _user} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Create another user to create a room (so it's not us)
      {:ok, other_user} =
        Accounts.Auth.register_user(%{
          username: "other_user",
          email: "other@test.com",
          password: "password123"
        })

      # Create a room
      {:ok, room} = RoomManager.create_room(other_user.id, %{name: "New Room"})

      # Should receive room_created push
      assert_push "room_created", %{room: created_room}, 1000
      assert created_room.code == room.code
    end

    test "does not broadcast single-player room creation", %{socket: socket} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      {:ok, other_user} =
        Accounts.Auth.register_user(%{
          username: "solo_creator",
          email: "solo_creator@test.com",
          password: "password123"
        })

      {:ok, _room} =
        RoomManager.create_room(other_user.id, %{name: "Solo Table", solo: true})

      refute_push "room_created", _payload, 200
    end

    test "broadcasts when player joins room", %{socket: socket, user: user} do
      # Create initial room
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Test Room"})

      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Create another user and have them join
      {:ok, other_user} =
        Accounts.Auth.register_user(%{
          username: "joiner",
          email: "joiner@test.com",
          password: "password123"
        })

      {:ok, _, _} = RoomManager.join_room(room.code, other_user.id)

      # Should receive room_updated push
      %{room: updated_room} = assert_push_for_room("room_updated", room.code)
      assert updated_room.code == room.code
      assert updated_room.player_count == 2
    end

    test "broadcasts when room becomes ready (4 players)", %{socket: socket, user: user} do
      # Create a room
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Full Room"})

      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Add 3 more players to reach 4 total
      other_users =
        Enum.map(1..3, fn i ->
          {:ok, u} =
            Accounts.Auth.register_user(%{
              username: "player#{i}",
              email: "player#{i}@test.com",
              password: "password123"
            })

          u
        end)

      # Join all 3 players
      Enum.each(other_users, fn u ->
        {:ok, _, _} = RoomManager.join_room(room.code, u.id)
        # Each join should broadcast room_updated
        assert_push "room_updated", %{room: _}, 1000
      end)
    end

    test "broadcasts when host leaves and room closes", %{socket: socket, user: user} do
      # Create a room
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Closing Room"})

      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      # Host leaves (this should close the room)
      :ok = RoomManager.leave_room(user.id)

      # Should receive room_closed
      assert_push "room_closed", %{room_code: code}, 1000
      assert code == room.code
    end
  end

  describe "multiple users in lobby" do
    test "all users receive room updates", %{user: user1} do
      # Create 3 users and have them all join lobby
      users =
        [user1] ++
          Enum.map(1..2, fn i ->
            {:ok, u} =
              Accounts.Auth.register_user(%{
                username: "multi_user#{i}",
                email: "multi#{i}@test.com",
                password: "password123"
              })

            u
          end)

      # All users join lobby
      sockets =
        Enum.map(users, fn user ->
          {:ok, socket} = create_socket(user)

          {:ok, _reply, socket} =
            subscribe_and_join(socket, LobbyChannel, "lobby", %{})

          socket
        end)

      # First user creates a room
      {:ok, room} = RoomManager.create_room(hd(users).id, %{name: "Shared Room"})

      # All sockets should receive the push messages
      Enum.each(sockets, fn _socket ->
        assert_push "room_created", %{room: created}, 1000
        assert created.code == room.code
      end)
    end
  end

  describe "room serialization" do
    test "serializes room data correctly", %{socket: socket, user: user} do
      # A free-form key is no longer carried through to the lobby: it is rejected.
      assert {:error, {:invalid_room_params, [%{field: "mode", message: _}]}} =
               RoomManager.create_room(user.id, %{name: "Test Room", mode: "competitive"})

      refute Enum.any?(RoomManager.list_rooms(:all), &(&1.host_id == user.id))

      {:ok, room} = RoomManager.create_room(user.id, %{name: "Test Room"})
      {:ok, _room} = RoomManager.set_locked(room.code, user.id, true)

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      assert %{rooms: rooms} = reply
      assert is_list(rooms)

      # Find our created room
      serialized_room = Enum.find(rooms, fn r -> r.code == room.code end)
      assert serialized_room != nil
      assert serialized_room.code == room.code
      assert serialized_room.host_id == user.id
      assert serialized_room.player_count == 1
      assert serialized_room.max_players == 4
      assert serialized_room.status == :waiting
      assert serialized_room.locked == true
      assert is_binary(serialized_room.created_at)

      assert serialized_room.config == %{
               name: "Test Room",
               bot_difficulty: "basic",
               rule_set: "finnish",
               solo: false
             }

      refute Map.has_key?(serialized_room, :metadata)
    end

    test "AE4: the lobby payload and the REST serializer report the same config", %{
      socket: socket,
      user: user
    } do
      {:ok, room} =
        RoomManager.create_room(user.id, %{name: "Friday", bot_difficulty: "smart"})

      {:ok, %{rooms: rooms}, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      lobby_room = Enum.find(rooms, &(&1.code == room.code))
      rest_room = RoomJSON.room(room)

      assert lobby_room.config == %{
               name: "Friday",
               bot_difficulty: "smart",
               rule_set: "finnish",
               solo: false
             }

      assert rest_room.config == lobby_room.config

      # Same shape on the wire, not only in Elixir terms.
      assert Jason.decode!(Jason.encode!(rest_room.config)) ==
               Jason.decode!(Jason.encode!(lobby_room.config))
    end

    test "a room created without a name serializes a null name on both transports", %{
      socket: socket,
      user: user
    } do
      {:ok, room} = RoomManager.create_room(user.id)

      {:ok, %{rooms: rooms}, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      lobby_room = Enum.find(rooms, &(&1.code == room.code))

      assert %{"name" => nil} = Jason.decode!(Jason.encode!(lobby_room.config))
      assert %{"name" => nil} = Jason.decode!(Jason.encode!(RoomJSON.room(room).config))
    end

    test "the room_created push carries the config", %{socket: socket} do
      {:ok, _reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      {:ok, room} = RoomManager.create_room("push-host", %{name: "Pushed"})

      assert_push "room_created", %{room: pushed}, 1000
      assert pushed.code == room.code

      assert pushed.config == %{
               name: "Pushed",
               bot_difficulty: "basic",
               rule_set: "finnish",
               solo: false
             }

      refute Map.has_key?(pushed, :metadata)
    end

    test "seats carry the display name; a guest shows their name, not the generated username",
         %{socket: socket} do
      guest = PidroServer.AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      {:ok, room} = RoomManager.create_room(guest.id, %{name: "Guest table"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      serialized_room = Enum.find(reply.rooms, fn r -> r.code == room.code end)
      north = Enum.find(serialized_room.seats, fn seat -> seat.position == :north end)

      assert north.player.id == guest.id
      assert north.player.username == guest.username
      assert north.player.display_name == "Anna"
      refute north.player.display_name == guest.username
    end

    test "lobby rows carry level and Legend stars; bot seats carry neither", %{socket: socket} do
      host = PidroServer.AccountsFixtures.user_fixture()
      {:ok, _} = PidroServer.Profiles.import_legacy_progression(host.id, %{xp: 2_800_000})
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Legend table"})

      assert {:ok, _, :east} =
               RoomManager.join_bot(room.code, "bot_#{room.code}_east", self(), :east)

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      seats = Enum.find(reply.rooms, &(&1.code == room.code)).seats
      player = &Enum.find(seats, fn seat -> seat.position == &1 end).player

      assert %{level: 100, prestige: 4, pin: "classic"} = player.(:north)
      assert %{level: nil, prestige: nil, pin: nil} = player.(:east)
    end

    test "a bot seat carries its persona; a human seat carries none", %{socket: socket} do
      host = PidroServer.AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Crew table"}, seed: 1)

      assert {:ok, _, :east} =
               RoomManager.join_bot(room.code, "bot_#{room.code}_east", self(), :east)

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      seats = Enum.find(reply.rooms, &(&1.code == room.code)).seats
      player = &Enum.find(seats, fn seat -> seat.position == &1 end).player

      assert %{
               is_bot: true,
               display_name: "Marcel",
               username: "Marcel",
               bot_persona: "marcel",
               avatar_url: avatar_url,
               bot_profile: %{id: "marcel", name: "Marcel"}
             } = player.(:east)

      assert avatar_url == PidroServerWeb.Endpoint.url() <> "/images/bots/marcel.svg"
      assert %{is_bot: false, bot_persona: nil} = player.(:north)
      assert player.(:north).username == host.username
    end

    test "a substitute bot for a disconnected human keeps the human's name and has no persona",
         %{socket: socket} do
      [host | _] = users = for _ <- 1..4, do: PidroServer.AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Subs"})
      for user <- tl(users), do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
      PidroServer.RoomFixtures.ready_room(room.code)

      gone = List.last(users)
      {:ok, playing} = RoomManager.get_room(room.code)
      position = Enum.find_value(playing.positions, fn {pos, id} -> if id == gone.id, do: pos end)

      :ok = RoomManager.handle_player_disconnect(room.code, gone.id)

      {:ok, substituted} =
        PidroServer.RoomManagerCase.expire_phase(room.code, position, :phase2_start)

      assert %{status: :bot_substitute, bot_persona: nil} = substituted.seats[position]

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      seat =
        Enum.find(
          Enum.find(reply.rooms, &(&1.code == room.code)).seats,
          &(&1.position == position)
        )

      assert %{username: username, bot_persona: nil, is_bot: false} = seat.player
      assert username == gone.username
    end

    test "a seat whose id resolves to nobody carries display_name nil", %{socket: socket} do
      {:ok, room} = RoomManager.create_room("dev_host", %{name: "Dev table"})

      {:ok, reply, _socket} = subscribe_and_join(socket, LobbyChannel, "lobby", %{})

      serialized_room = Enum.find(reply.rooms, fn r -> r.code == room.code end)
      north = Enum.find(serialized_room.seats, fn seat -> seat.position == :north end)

      assert north.player.is_bot == true
      assert north.player.display_name == nil
    end
  end

  defp assert_push_for_room(event, room_code, attempts \\ 5)

  defp assert_push_for_room(event, room_code, 0) do
    flunk("timed out waiting for #{event} for room #{room_code}")
  end

  defp assert_push_for_room(event, room_code, attempts) do
    assert_push ^event, payload, 1000

    if payload.room.code == room_code do
      payload
    else
      assert_push_for_room(event, room_code, attempts - 1)
    end
  end
end
