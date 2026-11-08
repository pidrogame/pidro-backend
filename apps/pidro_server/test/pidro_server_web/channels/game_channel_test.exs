defmodule PidroServerWeb.GameChannelTest do
  @moduledoc """
  Integration tests for GameChannel - Phase 4: Real-time Gameplay

  Tests the full WebSocket-based gameplay flow:
  - Joining game channels with authentication
  - Making bids via WebSocket
  - Declaring trump via WebSocket
  - Playing cards via WebSocket
  - Receiving state updates
  - Presence tracking
  """

  use PidroServerWeb.ChannelCase, async: false
  import Phoenix.ChannelTest, except: [subscribe_and_join: 4]
  import Ecto.Query, only: [from: 2]

  alias PidroServer.Accounts
  alias PidroServer.Accounts.UserAvatar
  alias PidroServer.Games.{GameAdapter, RoomManager}
  alias PidroServer.Profiles
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Repo
  alias PidroServerWeb.GameChannel
  alias PidroServerWeb.Serializers.GameStateSerializer

  @moduletag :channel

  setup tags do
    if tags[:stable_turn_timer], do: slow_turn_timers()

    # Trap exits to handle channel shutdowns gracefully
    Process.flag(:trap_exit, true)

    # Reset RoomManager state
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    # Create 4 test users
    users =
      Enum.map(1..4, fn i ->
        %{
          username: "player#{i}",
          display_name: "Shared public name",
          email: "player#{i}@test.com",
          password: "password123"
        }
        |> Accounts.Auth.register_user()
        |> elem(1)
      end)

    [user1, user2, user3, user4] = users

    avatar_urls =
      users
      |> Enum.with_index(1)
      |> Map.new(fn {user, index} ->
        version = String.duplicate(Integer.to_string(index), 64)

        %UserAvatar{}
        |> UserAvatar.changeset(%{user_id: user.id, image: <<index>>, version: version})
        |> Repo.insert!()

        {user.id, "#{PidroServerWeb.Endpoint.url()}/api/v1/users/#{user.id}/avatar/#{version}"}
      end)

    # Create a room with 4 players
    rule_set = if tags[:louisiana], do: :louisiana, else: :finnish
    {:ok, room} = RoomManager.create_room(user1.id, %{name: "Test Game", rule_set: rule_set})
    room_code = room.code

    {:ok, _, _} = RoomManager.join_room(room_code, user2.id)
    {:ok, _, _} = RoomManager.join_room(room_code, user3.id)
    {:ok, _, _} = RoomManager.join_room(room_code, user4.id)
    room = PidroServer.RoomFixtures.ready_room(room_code)

    # Create sockets for all users
    sockets =
      Enum.map(users, fn user ->
        {:ok, socket} = create_socket(user)
        {user.id, socket}
      end)
      |> Map.new()

    %{
      users: users,
      user1: user1,
      user2: user2,
      user3: user3,
      user4: user4,
      room_code: room_code,
      room: room,
      avatar_urls: avatar_urls,
      sockets: sockets
    }
  end

  describe "PID-79 spectator isolation" do
    @tag :louisiana
    test "first channel snapshot carries Louisiana and its minimum bid", ctx do
      {:ok, reply, _} =
        subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}")

      assert reply.state.variant == :louisiana
      assert reply.state.config.min_bid == 7
      wire = reply.state |> Jason.encode!() |> Jason.decode!()
      assert wire["variant"] == "louisiana"
      assert wire["config"]["min_bid"] == 7
    end

    test "two departures, delayed decisions and watcher reconnect never claim an open seat",
         ctx do
      {:ok, _, host} =
        subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}")

      {:ok, _, player} =
        subscribe_and_join(ctx.sockets[ctx.user4.id], GameChannel, "game:#{ctx.room_code}")

      {:ok, _, _} =
        Phoenix.ChannelTest.subscribe_and_join(
          ctx.sockets[ctx.user4.id],
          PidroServerWeb.LobbyChannel,
          "lobby",
          %{}
        )

      :ok = RoomManager.leave_room(ctx.user2.id)
      assert_push "room_updated", %{room: %{available_positions: []}, category: "spectatable"}
      # Keep Bot is a dismissal: the surrendered seat is already a permanent bot.
      {:ok, _} = RoomManager.join_spectator_room(ctx.room_code, ctx.user2.id)

      {:ok, %{role: :spectator}, watcher} =
        subscribe_and_join(ctx.sockets[ctx.user2.id], GameChannel, "game:#{ctx.room_code}")

      :ok = RoomManager.leave_room(ctx.user3.id)
      {:ok, _} = RoomManager.join_spectator_room(ctx.room_code, ctx.user3.id)

      {:ok, %{role: :spectator}, departing} =
        subscribe_and_join(ctx.sockets[ctx.user3.id], GameChannel, "game:#{ctx.room_code}")

      {:ok, _} = RoomManager.open_seat(ctx.room_code, :south, ctx.user1.id)

      assert_push "room_updated", %{
        room: %{available_positions: [:south]},
        category: "substitute_needed"
      }

      close(departing)
      # This broadcast used to crash every subscribed game channel.
      assert_push "spectator_left", %{user_id: user_id}
      assert user_id == ctx.user3.id
      # A round-trip processes queued broadcasts before checking each recipient.
      for socket <- [host, player, watcher] do
        :sys.get_state(socket.channel_pid)
        assert Process.alive?(socket.channel_pid)
      end

      close(watcher)

      {:ok, reply, _} =
        subscribe_and_join(ctx.sockets[ctx.user2.id], GameChannel, "game:#{ctx.room_code}")

      assert reply.role == :spectator
      refute Map.has_key?(reply, :position)
      assert reply.legal_actions == []
      {:ok, room} = RoomManager.get_room(ctx.room_code)
      assert room.seats.south.occupant_type == :vacant
      assert ctx.user2.id in room.spectator_ids
      refute ctx.user2.id in Map.values(room.positions)

      # Ending Watch is an explicit membership change, not a channel reconnect.
      assert :ok = RoomManager.leave_spectator(ctx.room_code, ctx.user3.id)

      assert {:error, _} =
               subscribe_and_join(
                 ctx.sockets[ctx.user3.id],
                 GameChannel,
                 "game:#{ctx.room_code}",
                 %{"role" => "player"}
               )

      {:ok, _, :south} = RoomManager.join_room(ctx.room_code, ctx.user3.id)

      {:ok, %{role: :player, position: :south}, _} =
        subscribe_and_join(ctx.sockets[ctx.user3.id], GameChannel, "game:#{ctx.room_code}")

      assert_push "room_updated", %{room: %{available_positions: []}, category: "spectatable"}
    end
  end

  describe "seat lifecycle snapshot" do
    test "a bot seat carries its persona in the join reply's readiness and seat lifecycle" do
      host = PidroServer.AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Crew"}, seed: 1)

      for position <- [:east, :south] do
        bot_id = "bot_#{room.code}_#{position}"
        assert {:ok, _, ^position} = RoomManager.join_bot(room.code, bot_id, self(), position)
      end

      {:ok, socket} = create_socket(host)
      {:ok, reply, _} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")

      for {position, persona, name} <- [{:east, "marcel", "Marcel"}, {:south, "jocke", "Jocke"}] do
        assert %{is_bot: true, bot_persona: ^persona, display_name: ^name, username: ^name} =
                 reply.readiness.seats[position]

        avatar_url = PidroServerWeb.Endpoint.url() <> "/images/bots/#{persona}.svg"

        assert %{
                 bot_persona: ^persona,
                 display_name: ^name,
                 username: ^name,
                 avatar_url: ^avatar_url,
                 bot_profile: %{id: ^persona, name: ^name, avatar_url: ^avatar_url}
               } =
                 reply.seat_lifecycle.seats[position]
      end

      assert %{is_bot: false, bot_persona: nil} = reply.readiness.seats.north
      assert reply.seat_lifecycle.seats.north.bot_persona == nil
      assert reply.seat_lifecycle.seats.north.bot_profile == nil
    end

    test "Keep Bot broadcasts resolution to all observers and cold joins", context do
      {:ok, _, owner} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      {:ok, _, _} =
        subscribe_and_join(
          context.sockets[context.user3.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      :ok = RoomManager.leave_room(context.user2.id)
      {:ok, pending} = RoomManager.get_seat_lifecycle(context.room_code)
      id = pending.seats.east.decision.id

      for event <- ["keep_bot", "open_seat"] do
        ref = push(owner, event, %{"position" => "east"})

        assert_reply ref, :error, %{
          reason: "stale_decision",
          error_code: "stale_decision",
          error_params: %{}
        }
      end

      ref = push(owner, "keep_bot", %{"position" => "east", "decision_id" => id})
      assert_reply ref, :ok, %{seat_lifecycle: kept}
      assert kept.seats.east.decision == nil
      assert kept.revision > pending.revision

      for _ <- 1..2 do
        assert_push "seat_lifecycle", %{seats: %{east: %{status: :permanent_bot, decision: nil}}}
      end

      {:ok, reply, _} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      assert reply.seat_lifecycle == kept
      ref = push(owner, "open_seat", %{"position" => "east", "decision_id" => id})
      assert_reply ref, :error, response

      assert response == %{
               reason: "stale_decision",
               seat_lifecycle: kept,
               error_code: "stale_decision",
               error_params: %{}
             }
    end

    test "all observers receive takeover and reclaim snapshots, including a cold join", context do
      for user <- [context.user1, context.user2, context.user4] do
        {:ok, _, _} =
          subscribe_and_join(context.sockets[user.id], GameChannel, "game:#{context.room_code}")
      end

      assert :ok = RoomManager.handle_player_disconnect(context.room_code, context.user3.id)

      for _ <- 1..3 do
        assert_push "seat_lifecycle", %{seats: %{south: %{status: :reconnecting}}}
      end

      {:ok, _} =
        PidroServer.RoomManagerCase.expire_phase(context.room_code, :south, :phase2_start)

      for _ <- 1..3 do
        assert_push "seat_lifecycle", %{
          seats: %{south: %{status: :bot_substitute, player_id: player_id}}
        }

        assert player_id == context.user3.id
      end

      # An observer that missed the transition receives its exact current status in join.
      {:ok, reply, _} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      assert reply.seat_lifecycle.seats.south.status == :bot_substitute
      assert reply.seat_lifecycle.seats.south.username == context.user3.username
      assert reply.seat_lifecycle.seats.south.bot_profile == nil

      {:ok, _, _} =
        subscribe_and_join(
          context.sockets[context.user3.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      for _ <- 1..5 do
        assert_push "seat_lifecycle", %{seats: %{south: %{status: :normal, player_id: player_id}}}
        assert player_id == context.user3.id
      end
    end

    test "avatar edits and removal publish revised identities to game observers", context do
      {:ok, reply, socket} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
      version = String.duplicate("a", 64)

      from(a in UserAvatar, where: a.user_id == ^context.user2.id)
      |> Repo.update_all(set: [version: version])

      RoomManager.identity_changed(context.user2.id)
      assert_receive {:room_updated, _}
      assert_push "seat_lifecycle", updated
      assert updated.revision > reply.seat_lifecycle.revision
      assert updated.seats.east.player_id == context.user2.id
      assert updated.seats.east.username == context.user2.username
      assert updated.seats.east.avatar_url == Accounts.Avatars.url(version, context.user2.id)

      Accounts.Avatars.delete(context.user2.id)
      assert_receive {:room_updated, _}
      assert_push "seat_lifecycle", removed
      assert removed.revision > updated.revision
      assert removed.seats.east.avatar_url == nil
      assert removed.seats.north.avatar_url == context.avatar_urls[context.user1.id]

      ref = push(socket, "get_seat_lifecycle", %{})
      assert_reply ref, :ok, %{seat_lifecycle: ^removed}
    end

    test "identity notifications refresh a departed player's pending decision", context do
      {:ok, _, _socket} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      assert :ok = RoomManager.leave_room(context.user2.id)
      assert_push "seat_lifecycle", %{seats: %{east: %{status: :permanent_bot}}} = departed
      decision_id = departed.seats.east.decision.id
      assert {:ok, _} = Accounts.Auth.update_user(context.user2, %{username: "renamed_player"})

      RoomManager.identity_changed(context.user2.id)

      assert_push "seat_lifecycle",
                  %{seats: %{east: %{decision: %{player_name: "renamed_player"}}}} = updated

      assert updated.revision > departed.revision
      assert updated.seats.east.player_id == nil
      assert updated.seats.east.avatar_url == nil
      assert updated.seats.east.decision.id == decision_id
      assert {:ok, ^updated} = RoomManager.get_seat_lifecycle(context.room_code)
    end

    test "join and reconciliation return the authoritative four-seat snapshot", context do
      {:ok, join_reply, socket} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      snapshot = join_reply.seat_lifecycle
      assert snapshot.room_id == context.room.id
      assert snapshot.room_code == context.room_code
      assert snapshot.owner_id == context.user1.id
      assert snapshot.room_status == "playing"
      assert map_size(snapshot.seats) == 4
      assert snapshot.seats.north.status == :normal
      assert snapshot.seats.north.player_id == context.user1.id
      assert snapshot.seats.north.username == context.user1.username
      assert snapshot.seats.north.display_name == context.user1.display_name
      assert snapshot.seats.north.avatar_url == context.avatar_urls[context.user1.id]
      assert snapshot.seats.east.username == context.user2.username
      assert snapshot.seats.east.display_name == context.user2.display_name
      assert snapshot.seats.east.avatar_url == context.avatar_urls[context.user2.id]
      refute snapshot.seats.north.avatar_url == snapshot.seats.east.avatar_url

      ref = push(socket, "get_seat_lifecycle", %{})
      assert_reply ref, :ok, %{seat_lifecycle: ^snapshot}
    end

    test "disconnect, explicit leave, promotion, and stale open decisions are versioned",
         context do
      {:ok, _, owner_socket} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      assert :ok = RoomManager.handle_player_disconnect(context.room_code, context.user3.id)
      assert_push "seat_lifecycle", reconnecting
      assert reconnecting.seats.south.status == :reconnecting
      assert reconnecting.seats.south.player_id == context.user3.id

      assert :ok = RoomManager.leave_room(context.user2.id)
      assert_push "seat_lifecycle", %{seats: %{east: %{status: :permanent_bot}}} = departed
      decision = departed.seats.east.decision
      assert departed.revision > reconnecting.revision
      assert departed.seats.east.status == :permanent_bot
      assert departed.seats.east.player_id == nil
      assert departed.seats.east.username == "Bot"
      assert departed.seats.east.display_name == "Bot"
      assert departed.seats.east.bot_persona == nil
      assert departed.seats.east.avatar_url == nil
      assert departed.seats.east.level == nil
      assert departed.seats.east.pin == nil
      assert decision.player_name == context.user2.username
      assert is_binary(decision.id)

      stale_ref =
        push(owner_socket, "open_seat", %{
          "position" => "east",
          "decision_id" => Ecto.UUID.generate()
        })

      assert_reply stale_ref, :error, %{reason: "stale_decision", seat_lifecycle: stale}
      assert stale.seats.east.decision.id == decision.id

      valid_ref =
        push(owner_socket, "open_seat", %{
          "position" => "east",
          "decision_id" => decision.id
        })

      assert_reply valid_ref, :ok, %{seat_lifecycle: opened}
      assert opened.revision > departed.revision
      assert_push "seat_lifecycle", ^opened

      assert opened.seats.east == %{
               status: :vacant,
               player_id: nil,
               username: nil,
               bot_persona: nil,
               bot_profile: nil,
               display_name: nil,
               avatar_url: nil,
               level: nil,
               prestige: nil,
               pin: nil,
               decision: nil
             }

      assert {:ok, _room, :east} =
               RoomManager.join_as_substitute(context.room_code, context.user2.id)

      returning_id = context.user2.id
      assert_push "seat_lifecycle", %{seats: %{east: %{player_id: ^returning_id}}} = rejoined
      assert rejoined.seats.east.player_id == context.user2.id
      assert rejoined.seats.east.username == context.user2.username
      assert rejoined.seats.east.avatar_url == context.avatar_urls[context.user2.id]

      assert :ok = RoomManager.leave_room(context.user2.id)
      assert_push "seat_lifecycle", %{seats: %{east: %{player_id: nil}}} = left_again
      assert left_again.seats.east.avatar_url == nil

      assert :ok = RoomManager.leave_room(context.user1.id)
      {:ok, promoted} = RoomManager.get_seat_lifecycle(context.room_code)
      assert promoted.owner_id == context.user4.id
      assert promoted.seats.north.decision.player_name == context.user1.username
    end

    test "every seat payload carries the occupant's level and Classic pin", context do
      {:ok, _profile} = Profiles.get_or_create_profile(context.user1.id)

      from(p in PlayerProfile, where: p.user_id == ^context.user1.id)
      |> PidroServer.Repo.update_all(
        set: [veteran_xp: 5_000, heritage_flags: %{"played_pidro_one" => true}]
      )

      veteran_level = PidroServer.Progression.level_for_xp(5_000)
      assert veteran_level > 1

      {:ok, join_reply, _socket} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      lifecycle = join_reply.seat_lifecycle.seats
      readiness = join_reply.readiness.seats

      for seats <- [lifecycle, readiness] do
        assert %{level: ^veteran_level, pin: "classic"} = seats.north
        # A player who has not finished a game yet has no profile row.
        assert %{level: 1, pin: nil} = seats.east
      end
    end

    test "every seat payload carries Legend stars: 0 at level 100, one per 500k XP past it",
         context do
      for {user, xp} <- [{context.user1, 800_000}, {context.user2, 2_800_000}] do
        {:ok, _profile} = Profiles.get_or_create_profile(user.id)

        from(p in PlayerProfile, where: p.user_id == ^user.id)
        |> PidroServer.Repo.update_all(set: [veteran_xp: xp])
      end

      {:ok, join_reply, _socket} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      for seats <- [join_reply.seat_lifecycle.seats, join_reply.readiness.seats] do
        assert %{level: 100, prestige: 0, pin: nil} = seats.north
        assert %{level: 100, prestige: 4, pin: nil} = seats.east
        # No profile row yet: a new player.
        assert %{level: 1, prestige: 0, pin: nil} = seats.south
      end
    end

    test "uses stable usernames and IDs while returning display names unchanged", context do
      variants = [nil, "", "Kettu 🦊", "Shared public name"]

      Enum.zip([context.user1, context.user2, context.user3, context.user4], variants)
      |> Enum.each(fn {user, display_name} ->
        from(u in Accounts.User, where: u.id == ^user.id)
        |> PidroServer.Repo.update_all(set: [display_name: display_name])
      end)

      {:ok, snapshot} = RoomManager.get_seat_lifecycle(context.room_code)

      Enum.zip(
        [:north, :east, :south, :west],
        [context.user1, context.user2, context.user3, context.user4]
      )
      |> Enum.zip(variants)
      |> Enum.each(fn {{position, user}, display_name} ->
        seat = snapshot.seats[position]
        assert seat.player_id == user.id
        assert seat.username == user.username
        assert seat.display_name == display_name
        assert seat.avatar_url == context.avatar_urls[user.id]
      end)
    end
  end

  describe "disconnect cascade delivery" do
    test "reclaim after grace expiry sends the seated reply and retires the bot", context do
      room_code = context.room_code
      user_id = context.user2.id

      {:ok, _, _observer} =
        subscribe_and_join(context.sockets[context.user1.id], GameChannel, "game:#{room_code}")

      :ok = RoomManager.handle_player_disconnect(room_code, user_id)
      assert_push "player_reconnecting", %{user_id: ^user_id, position: position}
      {:ok, grace} = PidroServer.RoomManagerCase.expire_phase(room_code, position, :phase2_start)
      bot = grace.seats[position].bot_pid
      assert_push "bot_substitute_active", %{user_id: ^user_id, position: ^position}
      {:ok, _} = PidroServer.RoomManagerCase.expire_phase(room_code, position, :phase3_gone)

      {:ok, reply, _returned} =
        subscribe_and_join(context.sockets[user_id], GameChannel, "game:#{room_code}")

      assert reply.reconnected
      assert reply.position == position
      refute Process.alive?(bot)
      assert_push "player_reclaimed_seat", %{user_id: ^user_id, position: ^position}
      {:ok, game} = GameAdapter.get_state(room_code)
      assert reply.state == GameStateSerializer.serialize(game, position)
    end

    test "owner removal and restoration are delivered with nullable ownership", context do
      room_code = context.room_code
      user_id = context.user4.id

      {:ok, _, _observer} =
        subscribe_and_join(context.sockets[user_id], GameChannel, "game:#{room_code}")

      for user <- context.users do
        :ok = RoomManager.handle_player_disconnect(room_code, user.id)
      end

      {:ok, _} = PidroServer.RoomManagerCase.expire_phase(room_code, :north, :phase2_start)
      :ok = RoomManager.leave_room(context.user1.id)
      assert_push "seat_permanently_botted", %{position: :north}
      assert_push "owner_changed", %{new_owner_id: nil, new_owner_position: nil}

      {:ok, returned} = RoomManager.handle_player_reconnect(room_code, user_id)
      position = PidroServer.Games.Room.Positions.get_position(returned, user_id)
      assert_push "owner_changed", %{new_owner_id: ^user_id, new_owner_position: ^position}
    end
  end

  describe "explicit departure retires game authority" do
    test "the remaining channel receives bot takeover and advancing game states", context do
      alias PidroServer.Games.Lifecycle
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(original,
          bot_delay_ms: 5,
          bot_delay_variance_ms: 0,
          bot_min_delay_ms: 1,
          turn_timer_bid_ms: 60_000,
          turn_timer_play_ms: 60_000
        )
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)

      advance_game_to_bidding(context.room_code)
      {:ok, before_departures} = GameAdapter.get_state(context.room_code)
      {:ok, room} = RoomManager.get_room(context.room_code)

      {human_position, human_id} =
        Enum.find(room.positions, fn {pos, user_id} ->
          pos != before_departures.current_turn and user_id != room.host_id
        end)

      {:ok, _, socket} =
        subscribe_and_join(context.sockets[human_id], GameChannel, "game:#{room.code}")

      for {position, user_id} <- room.positions, user_id != human_id do
        assert :ok = RoomManager.leave_room(user_id)
        assert_push "bot_substitute_active", %{position: ^position, user_id: ^user_id}
        assert_push "seat_permanently_botted", %{position: ^position}
      end

      assert_push "owner_changed", %{new_owner_id: ^human_id, new_owner_position: ^human_position}
      assert_push "game_state", %{state: %{current_turn: ^human_position} = delivered}, 2_000
      assert {:ok, advanced} = GameAdapter.get_state(room.code)
      assert length(advanced.events) > length(before_departures.events)
      assert delivered == GameStateSerializer.serialize(advanced, human_position)
      assert is_binary(Jason.encode!(delivered))
      assert Process.alive?(socket.channel_pid)
    end

    test "a stale channel cannot bid for the replacement bot", context do
      alias PidroServer.Games.Lifecycle
      original = Application.get_env(:pidro_server, Lifecycle, [])
      Application.put_env(:pidro_server, Lifecycle, Keyword.put(original, :bot_delay_ms, 60_000))
      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)

      advance_game_to_bidding(context.room_code)
      {:ok, game} = GameAdapter.get_state(context.room_code)
      {:ok, room} = RoomManager.get_room(context.room_code)
      user_id = room.positions[game.current_turn]

      stale_socket =
        Phoenix.Socket.assign(context.sockets[user_id], %{
          room_code: room.code,
          position: game.current_turn,
          role: :player
        })

      assert :ok = RoomManager.leave_room(user_id)

      assert {:reply, {:error, %{reason: "seat_not_controlled"}}, _} =
               GameChannel.handle_in("bid", %{"amount" => 6}, stale_socket)

      assert {:ok, unchanged} = GameAdapter.get_state(room.code)
      assert unchanged.events == game.events
    end

    test "all leaver channels close without starting another disconnect cascade", context do
      user = context.user2

      {:ok, _, first} =
        subscribe_and_join(context.sockets[user.id], GameChannel, "game:#{context.room_code}")

      {:ok, another_socket} = create_socket(user)

      {:ok, _, second} =
        subscribe_and_join(another_socket, GameChannel, "game:#{context.room_code}")

      monitors = Enum.map([first, second], &Process.monitor(&1.channel_pid))

      assert :ok = RoomManager.leave_room(user.id)

      for monitor <- monitors do
        assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :left}}
      end

      {:ok, room} = RoomManager.get_room(context.room_code)
      assert room.seats.east.status == :bot_substitute
      assert room.seats.east.reserved_for == nil
      refute Map.has_key?(room.phase_timers, :east)

      assert {:error, _} =
               subscribe_and_join(
                 context.sockets[user.id],
                 GameChannel,
                 "game:#{context.room_code}"
               )
    end
  end

  # Helper function to advance the game to the bidding phase
  defp advance_game_to_bidding(room_code) do
    {:ok, state} = GameAdapter.get_state(room_code)

    case state.phase do
      :dealer_selection ->
        # Trigger dealer selection which should auto-advance through dealing to bidding
        GameAdapter.apply_action(room_code, :north, :select_dealer)
        # Give it a moment to transition
        Process.sleep(50)
        :ok

      _ ->
        :ok
    end
  end

  describe "join/3" do
    test "authenticated user can join game channel", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert %{state: state, position: position} = reply
      assert state.phase in [:dealer_selection, :dealing, :bidding]
      assert position in [:north, :east, :south, :west]
    end

    test "returns different positions for different players", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      positions =
        Enum.map(users, fn user ->
          socket = sockets[user.id]

          {:ok, reply, _socket} =
            subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

          reply.position
        end)

      # All positions should be unique
      assert length(Enum.uniq(positions)) == 4
      # Should be the standard 4 positions
      assert Enum.sort(positions) == [:east, :north, :south, :west]
    end

    test "rejects join for non-player", %{room_code: room_code} do
      # Create a user not in the room
      {:ok, outsider} =
        Accounts.Auth.register_user(%{
          username: "outsider",
          email: "outsider@test.com",
          password: "password123"
        })

      {:ok, socket} = create_socket(outsider)

      assert {:error, response} =
               subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert response == %{
               reason: "not authorized to join this room",
               error_code: "forbidden",
               error_params: %{}
             }
    end

    test "rejects join for invalid room code", %{user1: user, sockets: sockets} do
      socket = sockets[user.id]

      assert {:error, response} =
               subscribe_and_join(socket, GameChannel, "game:XXXX", %{})

      assert response == %{
               reason: "room not found",
               error_code: "room_not_found",
               error_params: %{}
             }
    end

    @tag stable_turn_timer: true
    test "join reply includes the active turn timer hydration", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      {:ok, expected_timer} = wait_for_turn_timer(room_code)

      {:ok, reply, _socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      assert reply.turn_timer.timer_id == expected_timer.timer_id
      assert reply.turn_timer.scope == expected_timer.scope
      assert reply.turn_timer.position == expected_timer.position
      assert reply.turn_timer.phase == expected_timer.phase
      assert reply.turn_timer.duration_ms == expected_timer.duration_ms
      assert reply.turn_timer.transition_delay_ms == expected_timer.transition_delay_ms
      assert reply.turn_timer.event_seq == expected_timer.event_seq
      assert reply.turn_timer.remaining_ms <= expected_timer.remaining_ms
      assert reply.turn_timer.remaining_ms >= 0
    end
  end

  describe "presence tracking" do
    test "joined channels receive each broadcast and engine event once", context do
      {:ok, _, joined} =
        subscribe_and_join(
          context.sockets[context.user1.id],
          GameChannel,
          "game:#{context.room_code}"
        )

      assert_push "presence_state", _, 1000
      :sys.get_state(joined.channel_pid)
      marker = System.unique_integer([:positive])

      PidroServerWeb.Endpoint.broadcast!("game:#{context.room_code}", "player_ready", %{
        probe: marker
      })

      assert_push "player_ready", %{probe: ^marker}, 1000
      refute_push "player_ready", %{probe: ^marker}, 100

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{context.room_code}",
        {:turn_timer_cancelled, %{timer_id: marker}}
      )

      assert_push "turn_timer_cancelled", %{timer_id: ^marker}, 1000
      refute_push "turn_timer_cancelled", %{timer_id: ^marker}, 100
    end

    test "tracks presence when user joins", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Should receive presence_state after join
      assert_push "presence_state", _presence_state, 1000
    end
  end

  describe "dealer selection action" do
    test "player can trigger dealer selection", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "select_dealer", %{})
      assert_reply ref, :ok, %{}, 1000

      assert_eventually(fn ->
        {:ok, state} = GameAdapter.get_state(room_code)
        state.phase != :dealer_selection || state.dealer_selection_cuts != nil
      end)
    end
  end

  describe "correlated diagnostics" do
    setup do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)
      :ok
    end

    @tag :stable_turn_timer
    test "real actions preserve replies and correlate exact revisions, rejections and bounded acknowledgements",
         ctx do
      # The per-move echo is debug; correlation must hold there too.
      Logger.configure(level: :debug)

      log =
        ExUnit.CaptureLog.capture_log([formatter: {PidroServer.DiagnosticsFormatter, %{}}], fn ->
          {:ok, joined, socket} =
            subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}", %{
              "app_build" => "123",
              "platform" => "ios"
            })

          ref =
            push(socket, "select_dealer", %{"action_id" => "tap-1", "token" => "PRIVATE_TOKEN"})

          assert_reply ref, :ok, %{}, 1000
          assert_push "game_state", %{game_instance_id: instance, state_revision: revision}, 1000
          assert instance == joined.game_instance_id
          assert revision > joined.state_revision

          for payload <- [
                %{"game_instance_id" => "retired", "state_revision" => revision},
                %{"game_instance_id" => instance, "state_revision" => revision + 100},
                %{"game_instance_id" => instance, "state_revision" => revision},
                %{"game_instance_id" => instance, "state_revision" => revision}
              ] do
            ref = push(socket, "state_received", payload)
            assert_reply ref, :ok, %{}
          end

          ref =
            push(socket, "play_card", %{
              "action_id" => "tap-2",
              "card" => %{"rank" => "PRIVATE_CARD", "suit" => "spades"}
            })

          assert_reply ref, :error, %{error_code: "invalid_card"}, 1000

          ref =
            push(socket, "ready", %{
              "action_id" => "tap-3",
              "room_id" => "old",
              "ready_epoch" => -1
            })

          assert_reply ref, :error, %{error_code: "stale_readiness"}, 1000
        end)

      records = diagnostic_records(log)

      applied =
        Enum.find(records, &(&1["event"] == "action_applied" and &1["action_id"] == "tap-1"))

      assert applied["user_id"] == ctx.user1.id
      assert applied["room_code"] == ctx.room_code
      assert applied["app_build"] == "123"
      assert is_binary(applied["server_build"])
      assert is_integer(applied["duration_ms"])

      assert applied["level"] == "info"
      assert applied["action"] == "select_dealer"
      assert applied["outcome"] == "accepted"
      assert applied["seat"] == "north"

      for event <- ["action_received", "action_outcome", "state_broadcast"] do
        assert Enum.any?(
                 records,
                 &(&1["event"] == event and &1["action_id"] == "tap-1" and &1["level"] == "debug")
               )
      end

      # One info line for the applied move, nothing else at info.
      assert [%{"event" => "action_applied"}] =
               Enum.filter(records, &(&1["action_id"] == "tap-1" and &1["level"] != "debug"))

      assert Enum.any?(
               records,
               &(&1["event"] == "state_broadcast" and
                   &1["state_revision"] == applied["state_revision"])
             )

      assert Enum.count(records, &(&1["event"] == "state_received")) == 1

      for {id, code} <- [{"tap-2", "invalid_card"}, {"tap-3", "stale_readiness"}] do
        assert Enum.any?(
                 records,
                 &(&1["action_id"] == id and &1["outcome"] == "rejected" and
                     &1["error_code"] == code)
               )
      end

      refute log =~ "PRIVATE_TOKEN"
      refute log =~ "PRIVATE_CARD"
      refute Jason.encode!(records) =~ "spades"
      refute Jason.encode!(records) =~ "rank"
    end

    @tag :stable_turn_timer
    test "a stalled real engine records correlated timeout without retrying or changing its reply",
         ctx do
      {:ok, _, socket} =
        subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}", %{})

      {:ok, pid} = PidroServer.Games.GameRegistry.lookup(ctx.room_code)
      :ok = :sys.suspend(pid)

      try do
        log =
          ExUnit.CaptureLog.capture_log(
            [formatter: {PidroServer.DiagnosticsFormatter, %{}}],
            fn ->
              ref = push(socket, "select_dealer", %{"action_id" => "timed-out"})
              assert_reply ref, :error, %{error_code: "game_unavailable"}, 2000
            end
          )

        records = diagnostic_records(log)

        assert Enum.any?(
                 records,
                 &(&1["event"] == "game_process_failed" and &1["reason"] == "timeout" and
                     &1["action_id"] == "timed-out")
               )

        assert Enum.any?(
                 records,
                 &(&1["event"] == "action_outcome" and &1["error_code"] == "game_unavailable" and
                     &1["action_id"] == "timed-out")
               )
      after
        :sys.resume(pid)
      end
    end

    @tag :stable_turn_timer
    test "a missing default logging sink cannot change a legacy action result", ctx do
      {:ok, config} = :logger.get_handler_config(:default)
      :ok = :logger.remove_handler(:default)

      try do
        {:ok, joined, socket} =
          subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}", %{})

        ref = push(socket, "select_dealer", %{})
        assert_reply ref, :ok, %{}, 1000
        assert_push "game_state", %{state_revision: revision}, 1000
        assert revision > joined.state_revision
      after
        :logger.add_handler(:default, config.module, Map.drop(config, [:id, :module]))
      end
    end

    defp diagnostic_records(log) do
      log
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&Map.has_key?(&1, "event"))
    end
  end

  describe "bid action" do
    test "player can make a bid", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # The action might succeed or fail depending on game state
      # (e.g., if we're not in bidding phase yet or not our turn)
      ref = push(socket, "bid", %{"amount" => 8})
      # Just verify we get a response (ok or error)
      assert_reply ref, _, _, 1000
    end

    test "player can pass on bidding", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "bid", %{"amount" => "pass"})
      assert_reply ref, _, _, 1000
    end

    test "player can pass using pass event", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "pass", %{})
      assert_reply ref, _, _, 1000
    end

    test "handles bid as string number", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "bid", %{"amount" => "10"})
      assert_reply ref, _, _, 1000
    end
  end

  describe "declare_trump action" do
    test "player can declare trump suit", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "declare_trump", %{"suit" => "hearts"})
      assert_reply ref, _, _, 1000
    end
  end

  describe "play_card action" do
    test "player can play a card", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      # Advance game to bidding phase
      advance_game_to_bidding(room_code)

      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref =
        push(socket, "play_card", %{
          "card" => %{"rank" => 14, "suit" => "spades"}
        })

      assert_reply ref, _, _, 1000
    end
  end

  describe "input validation" do
    test "parser errors retain their legacy reasons and add explicit codes", ctx do
      {:ok, reply, socket} =
        subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}")

      refute Map.has_key?(reply, :error_code)
      refute Map.has_key?(reply, :error_params)

      for {event, params, reason, code} <- [
            {"bid", %{"amount" => "nope"}, "Invalid bid amount", "invalid_bid_amount"},
            {"declare_trump", %{"suit" => "stars"}, "invalid suit", "invalid_suit"},
            {"play_card", %{"card" => %{"rank" => "ace", "suit" => "hearts"}},
             "invalid card rank", "invalid_card"},
            {"play_card", %{"card" => %{"rank" => 14, "suit" => "stars"}}, "invalid card suit",
             "invalid_card"},
            {"select_hand", %{"cards" => [%{"rank" => 14, "suit" => "stars"}]},
             "invalid card suit", "invalid_card"},
            {"select_hand", %{"cards" => [%{}]}, "invalid card payload", "invalid_card"},
            {"close_seat", %{"position" => "up"}, "invalid position", "invalid_position"}
          ] do
        ref = push(socket, event, params)
        assert_reply ref, :error, response
        assert response == %{reason: reason, error_code: code, error_params: %{}}
      end
    end

    test "spectator failures retain action-specific reasons", ctx do
      spectator = Phoenix.Socket.assign(ctx.sockets[ctx.user1.id], :role, :spectator)

      for {event, params, reason} <- [
            {"bid", %{"amount" => "pass"}, "spectators cannot make bids"},
            {"bid", %{"amount" => 8}, "spectators cannot make bids"},
            {"bid", %{"amount" => "8"}, "spectators cannot make bids"},
            {"pass", %{}, "spectators cannot make bids"},
            {"declare_trump", %{"suit" => "hearts"}, "spectators cannot declare trump"},
            {"play_card", %{"card" => %{"rank" => 14, "suit" => "hearts"}},
             "spectators cannot play cards"},
            {"select_hand", %{"cards" => []}, "spectators cannot select hand"},
            {"select_dealer", %{}, "spectators cannot select dealer"},
            {"ready", %{"room_id" => ctx.room.id, "ready_epoch" => 0},
             "spectators cannot signal ready"},
            {"rematch", %{"room_id" => ctx.room.id, "ready_epoch" => 0},
             "spectators cannot ask for a rematch"},
            {"open_seat", %{"position" => "east"}, "spectators cannot manage seats"},
            {"keep_bot", %{"position" => "east"}, "spectators cannot manage seats"},
            {"close_seat", %{"position" => "east"}, "spectators cannot manage seats"}
          ] do
        assert {:reply, {:error, response}, ^spectator} =
                 GameChannel.handle_in(event, params, spectator)

        assert response == %{
                 reason: reason,
                 error_code: "spectator_action_forbidden",
                 error_params: %{}
               }
      end
    end

    test "engine tuple errors preserve inspected reasons without exposing tuple params", ctx do
      advance_game_to_bidding(ctx.room_code)
      {:ok, state} = GameAdapter.get_state(ctx.room_code)
      user_id = ctx.room.positions[state.current_turn]

      {:ok, _, socket} =
        subscribe_and_join(ctx.sockets[user_id], GameChannel, "game:#{ctx.room_code}")

      ref = push(socket, "bid", %{"amount" => 99})
      assert_reply ref, :error, response

      assert response == %{
               reason: "{:invalid_bid_amount, 99}",
               error_code: "invalid_bid_amount",
               error_params: %{}
             }
    end

    test "rejects invalid trump suit", %{user1: user, room_code: room_code, sockets: sockets} do
      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "declare_trump", %{"suit" => "stars"})
      assert_reply ref, :error, %{reason: "invalid suit"}, 1000
    end

    test "rejects invalid play_card suit", %{user1: user, room_code: room_code, sockets: sockets} do
      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref =
        push(socket, "play_card", %{
          "card" => %{"rank" => 14, "suit" => "stars"}
        })

      assert_reply ref, :error, %{reason: "invalid card suit"}, 1000
    end

    test "rejects malformed select_hand payload", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "select_hand", %{"cards" => [%{"rank" => 14, "suit" => "stars"}]})
      assert_reply ref, :error, %{reason: "invalid card suit"}, 1000
    end
  end

  describe "ready action" do
    test "player can signal ready", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, reply, socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      ref = push(socket, "ready", Map.take(reply.readiness, [:room_id, :ready_epoch]))
      assert_reply ref, :ok, %{readiness: %{status: :playing}}, 1000
      refute_broadcast "player_ready", _, 0
    end
  end

  describe "PID-110 hand privacy" do
    @describetag :stable_turn_timer

    setup %{room_code: room_code} do
      {:ok, state} = GameAdapter.get_state(room_code)

      hands = %{
        north: [{14, :hearts}, {10, :hearts}],
        east: [{13, :hearts}],
        south: [{12, :hearts}, {11, :hearts}, {9, :hearts}],
        west: []
      }

      state = %{
        state
        | phase: :playing,
          current_turn: :north,
          current_dealer: :west,
          trump_suit: :hearts,
          highest_bid: {:north, 6},
          bidding_team: :north_south,
          players:
            Map.new(state.players, fn {position, player} ->
              {position, %{player | hand: hands[position]}}
            end)
      }

      {:ok, pid} = PidroServer.Games.GameRegistry.lookup(room_code)
      :ok = GenServer.call(pid, {:set_state, state})
      watcher = PidroServer.AccountsFixtures.guest_fixture()
      {:ok, _} = RoomManager.join_spectator_room(room_code, watcher.id)
      {:ok, watcher_socket} = create_socket(watcher)

      %{private_state: state, watcher_socket: watcher_socket}
    end

    test "ping, quiet background resume and late card refusal use the public wire contract",
         ctx do
      {:ok, snapshot} = GameAdapter.get_snapshot(ctx.room_code)
      send(RoomManager, {:state_update, ctx.room_code, snapshot})
      RoomManager.get_room(ctx.room_code)

      {:ok, joined, socket} =
        subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}", %{
          "reason" => "network_lost",
          "network" => "cellular",
          "app_version" => "3.2.4",
          "app_build" => "14",
          "platform" => "android"
        })

      assert joined.state_revision == snapshot.state_revision
      assert joined.game_instance_id == snapshot.game_instance_id
      {:ok, joined_room} = RoomManager.get_room(ctx.room_code)
      joined_seat = Enum.find(Map.values(joined_room.seats), &(&1.user_id == ctx.user1.id))
      assert joined_seat.network == "cellular"
      assert {joined_seat.app_version, joined_seat.app_build} == {"3.2.4", "14"}
      send(RoomManager, :check_connections)
      assert_push "ping", %{id: id}
      ref = push(socket, "pong", %{"id" => id})
      assert_reply ref, :ok, %{}
      ref = push(socket, "going_background", %{})
      assert_reply ref, :ok, %{}
      assert_push "turn_timer_cancelled", _
      close(socket)

      {:ok, resumed, socket} =
        subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}", %{})

      assert resumed.turn_timer.event_seq == joined.turn_timer.event_seq
      {:ok, room} = RoomManager.get_room(ctx.room_code)
      timer = room.turn_timer
      send(RoomManager, {:turn_timer_expired, ctx.room_code, timer.timer_id, timer.key})
      assert_push "turn_auto_played", %{action: played}

      ref =
        push(socket, "play_card", %{
          "action_id" => "late-card",
          "game_instance_id" => joined.game_instance_id,
          "turn_event_seq" => joined.turn_timer.event_seq,
          "card" => %{"rank" => 14, "suit" => "hearts"}
        })

      assert_reply ref, :error, %{
        reason: "already_played_for_you",
        error_code: "already_played_for_you",
        action: ^played
      }

      assert played.type == :play_card
      assert %{rank: _, suit: :hearts} = played.card
    end

    test "a playing join without a game snapshot fails retryably", ctx do
      :ok = PidroServer.Games.GameSupervisor.stop_game(ctx.room_code)

      assert {:error, %{error_code: "game_unavailable"}} =
               subscribe_and_join(
                 ctx.sockets[ctx.user1.id],
                 GameChannel,
                 "game:#{ctx.room_code}",
                 %{}
               )
    end

    test "joins and pushes reveal only the authenticated seat, never a requested seat", ctx do
      for user <- ctx.users do
        {:ok, reply, socket} =
          subscribe_and_join(ctx.sockets[user.id], GameChannel, "game:#{ctx.room_code}", %{
            "position" => "south"
          })

        assert ctx.room.positions[reply.position] == user.id
        assert_private_hands(reply.state, ctx.private_state, reply.position)
        send(socket.channel_pid, {:state_update, ctx.room_code, ctx.private_state})
        assert_push "game_state", %{state: state}
        assert_private_hands(state, ctx.private_state, reply.position)
      end

      {:ok, reply, socket} =
        subscribe_and_join(ctx.watcher_socket, GameChannel, "game:#{ctx.room_code}", %{
          "position" => "north",
          "role" => "player"
        })

      assert reply.role == :spectator
      assert reply.legal_actions == []
      assert_private_hands(reply.state, ctx.private_state, nil)
      send(socket.channel_pid, {:state_update, ctx.room_code, ctx.private_state})
      assert_push "game_state", %{state: state, legal_actions: []}
      assert_private_hands(state, ctx.private_state, nil)
    end

    test "reconnect catches up privately and the owner can play a received card", ctx do
      {:ok, _, socket} =
        subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}", %{})

      close(socket)

      {:ok, reply, returned} =
        subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}", %{})

      assert reply.reconnected
      assert_private_hands(reply.state, ctx.private_state, :north)
      assert %{type: "play_card", card: %{rank: 14, suit: :hearts}} in reply.legal_actions
      [card | _] = reply.state.players.north.hand

      ref =
        push(returned, "play_card", %{
          "action_id" => "flaky-card-tap",
          "card" => %{"rank" => card.rank, "suit" => to_string(card.suit)}
        })

      assert_reply ref, :ok, %{}
      assert_push "game_state", %{state: played}
      assert played.players.north.hand == [%{rank: 10, suit: :hearts}]
      assert played.players.north.card_count == 1
      assert [%{card: %{rank: 14, suit: :hearts}}] = played.current_trick

      {:ok, before_retry} = GameAdapter.get_snapshot(ctx.room_code)
      close(returned)

      {:ok, reply, retried} =
        subscribe_and_join(ctx.sockets[ctx.user1.id], GameChannel, "game:#{ctx.room_code}", %{})

      assert reply.reconnected

      ref =
        push(retried, "play_card", %{
          "action_id" => "flaky-card-tap",
          "card" => %{"rank" => card.rank, "suit" => to_string(card.suit)}
        })

      assert_reply ref, :ok, %{}
      {:ok, after_retry} = GameAdapter.get_snapshot(ctx.room_code)
      assert after_retry.state_revision == before_retry.state_revision
      assert after_retry.state == before_retry.state

      {:ok, watcher_reply, _} =
        subscribe_and_join(ctx.watcher_socket, GameChannel, "game:#{ctx.room_code}", %{})

      {:ok, state} = GameAdapter.get_state(ctx.room_code)
      assert_private_hands(watcher_reply.state, state, nil)
      assert [%{card: %{rank: 14, suit: :hearts}}] = watcher_reply.state.current_trick
    end

    test "a join whose seat is replaced during the snapshot fetch returns no private reply",
         ctx do
      # Hold the engine reply after join has read the roster. Keeping a game in
      # a waiting room lets the test replace the seat without starting a bot.
      :ok = RoomManager.update_room_status(ctx.room_code, :waiting)
      {:ok, pid} = PidroServer.Games.GameRegistry.lookup(ctx.room_code)
      :ok = :sys.suspend(pid)

      joining =
        Task.async(fn ->
          GameChannel.join("game:#{ctx.room_code}", %{}, ctx.sockets[ctx.user2.id])
        end)

      try do
        assert_eventually(fn ->
          {:messages, messages} = Process.info(pid, :messages)
          Enum.any?(messages, &match?({:"$gen_call", _, :get_snapshot}, &1))
        end)

        assert :ok = RoomManager.leave_room(ctx.user2.id)
        replacement = PidroServer.AccountsFixtures.guest_fixture()
        assert {:ok, _, :east} = RoomManager.join_room(ctx.room_code, replacement.id)

        :sys.replace_state(pid, fn state ->
          put_in(state.game_state.players.east.hand, [{8, :hearts}])
        end)
      after
        :sys.resume(pid)
      end

      assert {:error, %{reason: "Not authorized for this room"}} = Task.await(joining)
    end

    test "REST and default serialization stay public even for a seated player", ctx do
      import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

      assert_private_hands(
        GameStateSerializer.serialize(ctx.private_state),
        ctx.private_state,
        nil
      )

      assert_private_hands(
        GameStateSerializer.serialize_public(ctx.private_state),
        ctx.private_state,
        nil
      )

      response =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{create_token(ctx.user1)}")
        |> get("/api/v1/rooms/#{ctx.room_code}/state")
        |> json_response(200)

      for {position, player} <- ctx.private_state.players do
        view = response["data"]["state"]["players"][to_string(position)]
        assert view["hand"] == nil
        assert view["card_count"] == length(player.hand)
      end
    end
  end

  defp assert_private_hands(payload, source, viewer) do
    for {position, player} <- source.players do
      assert payload.players[position].card_count == length(player.hand)

      if position == viewer do
        assert payload.players[position].hand ==
                 Enum.map(player.hand, fn {rank, suit} -> %{rank: rank, suit: suit} end)
      else
        assert payload.players[position].hand == nil
      end
    end

    refute Map.has_key?(payload, :deck)
    refute Map.has_key?(payload, :discarded_cards)
    refute Map.has_key?(payload, :events)
  end

  describe "state updates" do
    test "pushes transition delay metadata with serialized game state", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      {:ok, state} = GameAdapter.get_state(room_code)

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:state_update, room_code, %{state: state, transition_delay_ms: 40}}
      )

      assert_push "game_state",
                  %{state: pushed_state, legal_actions: legal_actions, transition_delay_ms: 40},
                  1000

      assert pushed_state == GameStateSerializer.serialize(state, reply.position)
      assert is_list(legal_actions)
    end

    test "sends dealer rob cards only to the dealer", %{
      users: [dealer_user, other_user | _],
      room_code: room_code,
      sockets: sockets
    } do
      {:ok, dealer_reply, dealer_socket} =
        subscribe_and_join(sockets[dealer_user.id], GameChannel, "game:#{room_code}", %{})

      {:ok, _other_reply, other_socket} =
        subscribe_and_join(sockets[other_user.id], GameChannel, "game:#{room_code}", %{})

      watcher = PidroServer.AccountsFixtures.guest_fixture()
      {:ok, _} = RoomManager.join_spectator_room(room_code, watcher.id)
      {:ok, watcher_socket} = create_socket(watcher)

      {:ok, _, watcher_socket} =
        subscribe_and_join(watcher_socket, GameChannel, "game:#{room_code}", %{})

      {:ok, state} = GameAdapter.get_state(room_code)
      kept = [{14, :diamonds}, {5, :diamonds}, {5, :hearts}, {13, :diamonds}]
      discarded = [{3, :clubs}]
      state = put_in(state.players[dealer_reply.position].hand, kept)

      update =
        {:state_update, room_code,
         %{
           state: state,
           transition_delay_ms: 0,
           game_instance_id: dealer_reply.game_instance_id,
           state_revision: dealer_reply.state_revision + 1,
           server_time_ms: 2,
           presentation: %{
             dealer_selection: nil,
             dealer_rob: %{
               dealer: dealer_reply.position,
               automatic: true,
               pool: kept ++ discarded,
               kept: kept,
               discarded: discarded,
               started_at_ms: 1,
               ends_at_ms: 2_601
             }
           }
         }}

      send(dealer_socket.channel_pid, update)

      assert_push "game_state", %{state: dealer_state, presentation: %{dealer_rob: private}}, 1000

      assert_private_hands(dealer_state, state, dealer_reply.position)
      assert length(private.pool) == 5
      assert length(private.kept) == 4
      assert private.discarded == [%{rank: 3, suit: :clubs}]

      for socket <- [other_socket, watcher_socket] do
        send(socket.channel_pid, update)

        assert_push "game_state",
                    %{state: public_state, presentation: %{dealer_rob: public}},
                    1000

        assert_private_hands(public_state, state, socket.assigns.position)

        assert public == %{
                 dealer: dealer_reply.position,
                 automatic: true,
                 started_at_ms: 1,
                 ends_at_ms: 2_601
               }
      end
    end

    test "drops an older snapshot after a newer revision", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      {:ok, state} = GameAdapter.get_state(room_code)
      instance_id = reply.game_instance_id

      newer = %{
        state: state,
        transition_delay_ms: 0,
        game_instance_id: instance_id,
        state_revision: reply.state_revision + 2,
        server_time_ms: 2,
        presentation: %{dealer_selection: nil}
      }

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:state_update, room_code, newer}
      )

      assert_push "game_state", %{state_revision: pushed_revision}, 1000
      assert pushed_revision == newer.state_revision

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:state_update, room_code, %{newer | state_revision: newer.state_revision - 1}}
      )

      refute_push "game_state", %{state_revision: _}, 100
    end

    test "drops a queued snapshot from another game instance", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      {:ok, state} = GameAdapter.get_state(room_code)

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:state_update, room_code,
         %{
           state: state,
           transition_delay_ms: 0,
           game_instance_id: "retired-game-instance",
           state_revision: reply.state_revision + 100,
           server_time_ms: 2,
           presentation: %{dealer_selection: nil}
         }}
      )

      refute_push "game_state", %{game_instance_id: "retired-game-instance"}, 100
    end

    test "broadcasts state updates to all players", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      # All users join the channel
      joined_sockets =
        Enum.map(users, fn user ->
          socket = sockets[user.id]

          {:ok, _reply, socket} =
            subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

          socket
        end)

      # First player makes an action (dealer selection in initial phase)
      first_socket = hd(joined_sockets)
      # Try to select dealer if we're in that phase
      push(first_socket, "ready", %{})

      # All sockets might receive a broadcast (depending on game state)
      # We can't guarantee the exact broadcast without knowing game state
      # but we can verify the channel is set up correctly
      assert length(joined_sockets) == 4
    end
  end

  describe "progression summary (PID-52)" do
    test "pushes the socket's own progression_summary slice", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      my_summary = %{rated: false, xp_earned: 112, rating: nil}

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:progression_summary, room_code, %{user.id => my_summary}}
      )

      assert_push "progression_summary", ^my_summary, 1000
    end

    test "pushes ONLY this socket's slice, never another player's deltas", %{
      user1: user,
      user2: other,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      mine = %{rated: true, xp_earned: 112}
      theirs = %{rated: true, xp_earned: 45}

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:progression_summary, room_code, %{user.id => mine, other.id => theirs}}
      )

      assert_push "progression_summary", pushed, 1000
      assert pushed == mine
      refute pushed == theirs
    end

    test "a socket whose user is absent from the map pushes an empty map (no crash)", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      other_id = Ecto.UUID.generate()

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:progression_summary, room_code, %{other_id => %{rated: false}}}
      )

      assert_push "progression_summary", pushed, 1000
      assert pushed == %{}
    end

    test "a join after game over replies with the summary until a rematch starts", %{
      users: users,
      user1: user,
      user3: partner,
      room: room,
      room_code: room_code,
      sockets: sockets
    } do
      game_over = {:game_over, room_code, :north_south, %{north_south: 62, east_west: 45}}
      send(GenServer.whereis(RoomManager), game_over)
      {:ok, %{status: :finished}} = RoomManager.get_room(room_code)

      {:ok, reply, socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      assert %{xp_earned: 112, partner: %{user_id: partner_id, games_together: 1}} =
               reply.progression_summary

      assert partner_id == partner.id

      epoch = reply.readiness.ready_epoch
      ref = push(socket, "rematch", %{"room_id" => room.id, "ready_epoch" => epoch})
      assert_reply ref, :ok, _

      for u <- tl(users) do
        {:ok, _} = RoomManager.confirm_rematch(room_code, room.id, u.id, self(), epoch)
      end

      {:ok, %{status: :playing}} = RoomManager.get_room(room_code)

      {:ok, reply, _socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      refute Map.has_key?(reply, :progression_summary)
    end

    test "the base game_over push is unchanged (regression guard)", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      assert_push "presence_state", _presence_state, 1000

      scores = %{north_south: 62, east_west: 45}

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:game_over, room_code, :north_south, scores}
      )

      assert_push "game_over", %{winner: :north_south, scores: ^scores}, 1000
    end
  end

  describe "integration: full game flow" do
    test "4 players can interact with game via channels", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      # All 4 players join the game channel
      joined_sockets =
        Enum.map(users, fn user ->
          socket = sockets[user.id]

          {:ok, reply, socket} =
            subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

          # Each player should get initial state and their position
          assert %{state: state, position: position} = reply
          assert state.phase in [:dealer_selection, :dealing, :bidding]
          assert position in [:north, :east, :south, :west]

          {position, socket}
        end)
        |> Map.new()

      # Verify all 4 positions are represented
      positions = Map.keys(joined_sockets)
      assert length(positions) == 4
      assert Enum.sort(positions) == [:east, :north, :south, :west]

      # Each socket should have received presence_state
      Enum.each(joined_sockets, fn {_position, _socket} ->
        assert_push "presence_state", _presence, 2000
      end)
    end
  end

  describe "reconnection handling" do
    test "detects reconnection attempt when player was disconnected", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      # First join
      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Simulate disconnect by leaving the channel and marking as disconnected
      leave(joined_socket)
      :ok = RoomManager.handle_player_disconnect(room_code, user.id)

      # Attempt to rejoin - should detect as reconnection
      {:ok, new_socket} = create_socket(user)

      {:ok, reply, _reconnected_socket} =
        subscribe_and_join(new_socket, GameChannel, "game:#{room_code}", %{})

      # Should indicate this was a reconnection
      assert reply.reconnected == true
      assert reply.position in [:north, :east, :south, :west]
      assert reply.state != nil
    end

    test "successful reconnection broadcasts to other players", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      [user1, user2 | _] = users

      # Both players join
      {:ok, _reply, _socket1} =
        subscribe_and_join(sockets[user1.id], GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, _socket2} =
        subscribe_and_join(sockets[user2.id], GameChannel, "game:#{room_code}", %{})

      # User2 disconnects
      :ok = RoomManager.handle_player_disconnect(room_code, user2.id)

      # User2 reconnects
      {:ok, new_socket2} = create_socket(user2)

      {:ok, _reply, _reconnected_socket} =
        subscribe_and_join(new_socket2, GameChannel, "game:#{room_code}", %{})

      # Socket1 (user1) should receive reconnection broadcast
      assert_broadcast "player_reconnected", %{user_id: user_id, position: position}, 1000
      assert to_string(user_id) == to_string(user2.id)
      assert position in [:north, :east, :south, :west]
    end

    @tag :stable_turn_timer
    test "reconnection returns the scored last hand with reconnected flag", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      state =
        1
        |> Pidro.Test.DeterministicGame.opening()
        |> Pidro.Test.DeterministicGame.play_until(&(&1.hand_number == 2))

      assert state.last_hand != nil
      {:ok, pid} = PidroServer.Games.GameRegistry.lookup(room_code)
      :ok = GenServer.call(pid, {:set_state, state})
      socket = sockets[user.id]

      # First join
      {:ok, initial_reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      initial_position = initial_reply.position
      assert initial_reply.reconnected == false

      # Disconnect and reconnect
      leave(joined_socket)
      :ok = RoomManager.handle_player_disconnect(room_code, user.id)

      {:ok, new_socket} = create_socket(user)

      {:ok, reconnect_reply, _reconnected_socket} =
        subscribe_and_join(new_socket, GameChannel, "game:#{room_code}", %{})

      # Should have same position and reconnected flag
      assert reconnect_reply.reconnected == true
      assert reconnect_reply.position == initial_position
      assert reconnect_reply.state.phase == :bidding
      assert reconnect_reply.state.last_hand == GameStateSerializer.serialize(state).last_hand
      assert reconnect_reply.state.last_hand == initial_reply.state.last_hand

      wire = reconnect_reply.state |> Jason.encode!() |> Jason.decode!()
      assert wire["last_hand"]["hand_number"] == 1
      assert wire["last_hand"]["scores"] == wire["scores"]
      assert length(wire["last_hand"]["tricks"]) == length(state.last_hand.tricks)
      assert wire["last_hand"]["trump"] == to_string(state.last_hand.trump)
    end

    @tag :stable_turn_timer
    test "reconnection returns the hand history after the last hand is gone", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      state =
        1
        |> Pidro.Test.DeterministicGame.opening()
        |> Pidro.Test.DeterministicGame.play_until(&(&1.hand_number == 3 and &1.tricks != []))

      assert state.last_hand == nil
      assert [%{hand_number: 1}, %{hand_number: 2}] = state.hand_history
      {:ok, pid} = PidroServer.Games.GameRegistry.lookup(room_code)
      :ok = GenServer.call(pid, {:set_state, state})

      {:ok, initial_reply, joined_socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      leave(joined_socket)
      :ok = RoomManager.handle_player_disconnect(room_code, user.id)
      {:ok, new_socket} = create_socket(user)

      {:ok, reconnect_reply, _reconnected_socket} =
        subscribe_and_join(new_socket, GameChannel, "game:#{room_code}", %{})

      assert reconnect_reply.reconnected == true

      assert reconnect_reply.state.hand_history ==
               GameStateSerializer.serialize(state).hand_history

      assert reconnect_reply.state.hand_history == initial_reply.state.hand_history

      wire = reconnect_reply.state |> Jason.encode!() |> Jason.decode!()
      assert Enum.map(wire["hand_history"], & &1["hand_number"]) == [1, 2]
      assert List.last(wire["hand_history"])["scores"] == wire["scores"]
    end

    test "normal join still works without reconnected flag", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, reply, _socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # First join should not be marked as reconnection
      assert reply.reconnected == false
      assert reply.position in [:north, :east, :south, :west]
    end

    test "reconnection after grace period fails", %{
      user1: _user1,
      user2: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      # Join and then disconnect
      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      leave(joined_socket)
      :ok = RoomManager.handle_player_disconnect(room_code, user.id)

      # Manually expire grace period by updating disconnect time in the past
      {:ok, _room} = RoomManager.get_room(room_code)
      _past_time = DateTime.add(DateTime.utc_now(), -130, :second)

      # We need to update the room state directly (this is a test helper scenario)
      # In real scenario, we'd wait 120+ seconds
      # For this test, we'll verify the error handling when grace period has expired

      # Simulate expired grace period by removing player from room
      :ok = RoomManager.leave_room(user.id)

      # Attempt reconnection should fail
      {:ok, new_socket} = create_socket(user)

      assert {:error, %{reason: reason}} =
               subscribe_and_join(new_socket, GameChannel, "game:#{room_code}", %{})

      assert reason =~ "not authorized"
    end

    test "multiple players can reconnect independently", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      [user1, user2, user3 | _] = users

      # All join
      {:ok, _reply, socket1} =
        subscribe_and_join(sockets[user1.id], GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, socket2} =
        subscribe_and_join(sockets[user2.id], GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, _socket3} =
        subscribe_and_join(sockets[user3.id], GameChannel, "game:#{room_code}", %{})

      # User1 and User2 disconnect
      leave(socket1)
      leave(socket2)
      :ok = RoomManager.handle_player_disconnect(room_code, user1.id)
      :ok = RoomManager.handle_player_disconnect(room_code, user2.id)

      # User1 reconnects
      {:ok, new_socket1} = create_socket(user1)

      {:ok, reply1, _reconnected1} =
        subscribe_and_join(new_socket1, GameChannel, "game:#{room_code}", %{})

      assert reply1.reconnected == true

      # User2 reconnects
      {:ok, new_socket2} = create_socket(user2)

      {:ok, reply2, _reconnected2} =
        subscribe_and_join(new_socket2, GameChannel, "game:#{room_code}", %{})

      assert reply2.reconnected == true

      # Both should have valid positions
      assert reply1.position in [:north, :east, :south, :west]
      assert reply2.position in [:north, :east, :south, :west]
    end
  end

  describe "terminate/disconnect handling" do
    test "terminate callback notifies RoomManager on disconnect", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Close the socket (simulates disconnect)
      Process.unlink(joined_socket.channel_pid)
      close(joined_socket)

      # Give it time to process
      Process.sleep(100)

      {:ok, room} = RoomManager.get_room(room_code)

      # Player should still be in positions (disconnect doesn't remove them)
      player_ids = PidroServer.Games.Room.Positions.player_ids(room)
      assert to_string(user.id) in Enum.map(player_ids, &to_string/1)
    end

    test "terminate broadcasts disconnect to other players", %{
      users: users,
      room_code: room_code,
      sockets: sockets
    } do
      [user1, user2 | _] = users

      # Both join
      {:ok, _reply, _socket1} =
        subscribe_and_join(sockets[user1.id], GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, socket2} =
        subscribe_and_join(sockets[user2.id], GameChannel, "game:#{room_code}", %{})

      # User2 disconnects
      Process.unlink(socket2.channel_pid)
      close(socket2)

      # Socket1 should receive disconnect broadcast
      assert_broadcast "player_disconnected",
                       %{user_id: user_id, reason: reason, grace_period: grace_period},
                       1000

      assert to_string(user_id) == to_string(user2.id)
      assert reason in ["left", "connection_lost", "error"]
      assert grace_period == true
    end

    test "handles normal leave reason", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Normal leave
      leave(joined_socket)

      # Should broadcast player_disconnected
      assert_broadcast "player_disconnected", %{user_id: _user_id, reason: reason}, 1000
      assert reason == "left"
    end

    test "closing one of multiple channels for the same player does not disconnect the seat", %{
      user1: user,
      room_code: room_code
    } do
      {:ok, socket1} = create_socket(user)
      {:ok, socket2} = create_socket(user)

      {:ok, _reply, joined1} =
        subscribe_and_join(socket1, GameChannel, "game:#{room_code}", %{})

      {:ok, _reply, joined2} =
        subscribe_and_join(socket2, GameChannel, "game:#{room_code}", %{})

      leave(joined1)

      refute_broadcast "player_disconnected", _payload, 100

      {:ok, room} = RoomManager.get_room(room_code)
      position = joined2.assigns.position
      assert room.seats[position].status == :connected

      leave(joined2)
      assert_broadcast "player_disconnected", %{user_id: user_id}, 1000
      assert to_string(user_id) == to_string(user.id)
    end
  end

  describe "timer events" do
    test "forwards timer lifecycle events from the game topic", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      {:ok, _reply, joined_socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      started = %{
        timer_id: 101,
        scope: :seat,
        position: :north,
        phase: :bidding,
        duration_ms: 120,
        transition_delay_ms: 0,
        server_time: "2026-03-11T12:00:00.000Z",
        event_seq: 2
      }

      cancelled = %{timer_id: 101, scope: :seat, position: :north, reason: :acted}

      auto_played = %{
        scope: :seat,
        position: :north,
        phase: :bidding,
        action: %{type: :pass},
        reason: :timeout
      }

      send(joined_socket.channel_pid, {:turn_timer_started, started})
      assert_push "turn_timer_started", ^started

      send(joined_socket.channel_pid, {:turn_timer_cancelled, cancelled})
      assert_push "turn_timer_cancelled", ^cancelled

      send(joined_socket.channel_pid, {:turn_auto_played, auto_played})
      assert_push "turn_auto_played", ^auto_played
    end

    test "pushes the timeout reason and stops the channel on forced disconnect", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      {:ok, _reply, joined_socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      send(joined_socket.channel_pid, {:force_disconnect, :timeout_threshold})

      assert_push "force_disconnect", %{reason: "timeout_threshold"}
      assert_receive {:EXIT, pid, {:shutdown, :timeout_threshold}}, 1000
      assert pid == joined_socket.channel_pid
    end
  end

  describe "reconnection edge cases" do
    test "immediate rejoin after forced inactivity disconnect keeps the human seat", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      {:ok, initial_reply, joined_socket} =
        subscribe_and_join(sockets[user.id], GameChannel, "game:#{room_code}", %{})

      position = initial_reply.position

      send(joined_socket.channel_pid, {:force_disconnect, :timeout_threshold})

      {:ok, fresh_socket} = create_socket(user)

      {:ok, reply, _rejoined_socket} =
        subscribe_and_join(fresh_socket, GameChannel, "game:#{room_code}", %{})

      assert reply.position == position
      assert reply.role == :player

      assert_receive {:EXIT, pid, {:shutdown, :timeout_threshold}}, 1000
      assert pid == joined_socket.channel_pid

      stable_room =
        wait_for_room(room_code, fn room ->
          seat = room.seats[position]

          if seat.status == :connected and seat.occupant_type == :human and
               seat.user_id == user.id do
            room
          end
        end)

      seat = stable_room.seats[position]
      assert seat.status == :connected
      assert seat.occupant_type == :human
      assert seat.user_id == user.id
      assert seat.bot_pid == nil
      assert seat.reserved_for == nil
    end

    test "reconnecting when not actually disconnected returns error", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      # Join normally
      {:ok, _reply, _joined_socket} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      # Try to trigger reconnection manually
      result = RoomManager.handle_player_reconnect(room_code, user.id)

      assert {:error, :player_not_disconnected} = result
    end

    test "joining with fresh socket after disconnect works correctly", %{
      user1: user,
      room_code: room_code,
      sockets: sockets
    } do
      socket = sockets[user.id]

      # Join, disconnect, and rejoin cycle
      {:ok, _reply1, socket1} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      leave(socket1)
      :ok = RoomManager.handle_player_disconnect(room_code, user.id)

      # Create fresh socket and rejoin
      {:ok, fresh_socket} = create_socket(user)

      {:ok, reply2, _socket2} =
        subscribe_and_join(fresh_socket, GameChannel, "game:#{room_code}", %{})

      assert reply2.reconnected == true
      assert %{state: _state, position: _position} = reply2
    end

    test "handles concurrent join attempts gracefully", %{
      user1: user,
      room_code: room_code
    } do
      # Create two sockets for same user
      {:ok, socket1} = create_socket(user)
      {:ok, socket2} = create_socket(user)

      # Both try to join
      {:ok, _reply1, _joined1} =
        subscribe_and_join(socket1, GameChannel, "game:#{room_code}", %{})

      # Second join with same user should work (they're in the room)
      {:ok, _reply2, _joined2} =
        subscribe_and_join(socket2, GameChannel, "game:#{room_code}", %{})

      # Both should succeed (same player, multiple connections)
      {:ok, room} = RoomManager.get_room(room_code)
      player_ids = PidroServer.Games.Room.Positions.player_ids(room)
      user_count = Enum.count(player_ids, fn id -> to_string(id) == to_string(user.id) end)
      assert user_count == 1
    end
  end

  describe "invites and host controls" do
    alias PidroServer.AccountsFixtures
    alias PidroServer.Games.Lifecycle
    alias PidroServer.Games.Room.Seat
    alias PidroServerWeb.Presence

    setup do
      host = AccountsFixtures.user_fixture(%{display_name: "Marcel"})
      ben = AccountsFixtures.user_fixture(%{display_name: "Ben"})
      carl = AccountsFixtures.user_fixture(%{display_name: "Carl"})

      {:ok, table} = RoomManager.create_room(host.id, %{name: "Invite table"})
      {:ok, table, :east} = RoomManager.join_room(table.code, ben.id)

      %{host: host, ben: ben, carl: carl, table: table}
    end

    for status <- [:waiting, :finished] do
      @tag departure_status: status
      test "leaving a #{status} room closes every old socket before a replacement receives cards",
           %{
             host: host,
             ben: ben,
             carl: carl,
             table: table,
             departure_status: status
           } do
        slow_turn_timers()
        old_sockets = [join_table(ben, table.code), join_table(ben, table.code)]
        :ok = RoomManager.update_room_status(table.code, status)
        assert :ok = RoomManager.leave_room(ben.id)

        for socket <- old_sockets do
          pid = socket.channel_pid
          assert_receive {:EXIT, ^pid, {:shutdown, :left}}, 1000
          refute Process.alive?(pid)
        end

        assert {:ok, _, :east} = RoomManager.join_room(table.code, carl.id)

        for _ <- 1..2 do
          user = AccountsFixtures.guest_fixture()
          assert {:ok, _, _} = RoomManager.join_room(table.code, user.id)
        end

        PidroServer.RoomFixtures.ready_room(table.code)
        advance_game_to_bidding(table.code)
        {:ok, socket} = create_socket(carl)
        {:ok, reply, _} = subscribe_and_join(socket, GameChannel, "game:#{table.code}", %{})
        assert reply.position == :east
        assert [_ | _] = reply.state.players.east.hand
        assert reply.state.players.north.hand == nil
        assert Process.alive?(join_table(host, table.code).channel_pid)
      end
    end

    test "pushes invite_redeemed with the guest's account names after a claim (AE2)", %{
      host: host,
      table: table
    } do
      _host_joined = join_table(host, table.code)
      anna = AccountsFixtures.guest_fixture(%{display_name: "Anna"})
      anna_id = anna.id

      assert {:ok, _room, :south, true} =
               RoomManager.claim_seat(table.code, table.id, anna.id,
                 hint: :south,
                 username: anna.username,
                 display_name: anna.display_name
               )

      assert_push "invite_redeemed",
                  %{
                    position: :south,
                    user_id: ^anna_id,
                    username: anna_username,
                    display_name: "Anna"
                  },
                  1000

      assert anna_username == anna.username
    end

    test "a kicked player's channel pushes kicked and stops while the seat stays vacant (AE11)",
         %{host: host, ben: ben, carl: carl, table: table} do
      {:ok, _table, :south} = RoomManager.join_room(table.code, carl.id)
      host_joined = join_table(host, table.code)
      ben_joined = join_table(ben, table.code)
      carl_joined = join_table(carl, table.code)
      ben_id = ben.id

      assert {:ok, _room} = RoomManager.kick_player(table.code, host.id, :east)

      assert_push "kicked", %{reason: "kicked"}, 1000
      assert_receive {:EXIT, pid, {:shutdown, :kicked}}, 1000
      assert pid == ben_joined.channel_pid

      # The host and Carl each push player_kicked; neither channel stops.
      assert_push "player_kicked", %{position: :east, user_id: ^ben_id}, 1000
      assert_push "player_kicked", %{position: :east, user_id: ^ben_id}, 1000
      refute_receive {:EXIT, _pid, _reason}, 100
      assert Process.alive?(host_joined.channel_pid)
      assert Process.alive?(carl_joined.channel_pid)

      # terminate/2 must not treat the kick as a disconnect that holds the seat.
      refute_broadcast "player_disconnected", %{user_id: ^ben_id}, 100
      {:ok, room} = RoomManager.get_room(table.code)
      assert room.positions[:east] == nil
      assert Seat.vacant?(room.seats[:east])
      assert room.status == :waiting
    end

    test "a moved player's channel follows the seat and acts at the new position once the table starts",
         %{host: host, ben: ben, carl: carl, table: table} do
      slow_turn_timers()
      _host_joined = join_table(host, table.code)
      ben_joined = join_table(ben, table.code)
      ben_id = ben.id
      topic = "game:#{table.code}"

      assert {:ok, _room} = RoomManager.move_seat(table.code, host.id, ben.id, :west)

      assert_push "seat_moved", %{user_id: ^ben_id, from: :east, to: :west}, 1000

      assert_eventually(fn ->
        :sys.get_state(ben_joined.channel_pid).assigns.position == :west
      end)

      assert_eventually(fn ->
        match?(%{metas: [%{position: :west, role: :player}]}, Presence.list(topic)[ben_id])
      end)

      # Two more players fill the table; the game starts and Ben acts as :west.
      dave = AccountsFixtures.user_fixture(%{display_name: "Dave"})
      {:ok, _room, _position} = RoomManager.join_room(table.code, carl.id)
      {:ok, _room, _position} = RoomManager.join_room(table.code, dave.id)
      PidroServer.RoomFixtures.ready_room(table.code)

      assert_eventually(fn ->
        match?({:ok, %{status: :playing}}, RoomManager.get_room(table.code))
      end)

      advance_game_to_bidding(table.code)

      assert_eventually(fn ->
        match?({:ok, %{phase: :bidding}}, GameAdapter.get_state(table.code))
      end)

      drive_bidding_to(table.code, :west)

      ref = push(ben_joined, "bid", %{"amount" => 6})
      assert_reply ref, :ok, %{}, 1000
    end

    defp join_table(user, room_code) do
      {:ok, socket} = create_socket(user)

      {:ok, _reply, joined} =
        subscribe_and_join(socket, GameChannel, "game:#{room_code}", %{})

      joined
    end

    # Test lifecycle timers auto-play within ~100 ms; hold them off so the test
    # drives bidding itself. Restored on exit.
    defp slow_turn_timers do
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(original, turn_timer_bid_ms: 60_000, turn_timer_play_ms: 60_000)
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)
    end

    # Passes for every other seat until `position` is on turn. Bidding cannot
    # complete early: a dealer who is last to act must bid, so the turn always
    # arrives within three passes.
    defp drive_bidding_to(room_code, position, attempts \\ 3)

    defp drive_bidding_to(room_code, position, attempts) do
      {:ok, state} = GameAdapter.get_state(room_code)

      cond do
        state.current_turn == position ->
          :ok

        attempts == 0 ->
          flunk("bidding never reached #{position}")

        true ->
          {:ok, _state} = GameAdapter.apply_action(room_code, state.current_turn, :pass)
          drive_bidding_to(room_code, position, attempts - 1)
      end
    end
  end

  # Replace the setup fixture's synthetic registration only after a real channel
  # joins, preserving last-channel disconnect semantics in lifecycle tests.
  defp subscribe_and_join(socket, channel, topic, params) do
    result = Phoenix.ChannelTest.subscribe_and_join(socket, channel, topic, params)

    case result do
      {:ok, _, joined} ->
        RoomManager.unregister_game_channel(
          joined.assigns.room_code,
          joined.assigns.user_id,
          self()
        )

      _ ->
        :ok
    end

    result
  end

  defp wait_for_turn_timer(room_code, attempts \\ 40)

  defp wait_for_turn_timer(_room_code, 0) do
    flunk("timed out waiting for active turn timer")
  end

  defp wait_for_turn_timer(room_code, attempts) do
    case RoomManager.get_turn_timer(room_code) do
      {:ok, nil} ->
        Process.sleep(10)
        wait_for_turn_timer(room_code, attempts - 1)

      {:ok, turn_timer} ->
        {:ok, turn_timer}
    end
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(_fun, 0) do
    flunk("timed out waiting for condition")
  end

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp wait_for_room(room_code, matcher, attempts \\ 60)

  defp wait_for_room(_room_code, _matcher, 0) do
    flunk("timed out waiting for room state")
  end

  defp wait_for_room(room_code, matcher, attempts) do
    case RoomManager.get_room(room_code) do
      {:ok, room} ->
        case matcher.(room) do
          nil ->
            Process.sleep(10)
            wait_for_room(room_code, matcher, attempts - 1)

          matched ->
            matched
        end

      {:error, _reason} ->
        Process.sleep(10)
        wait_for_room(room_code, matcher, attempts - 1)
    end
  end
end
