defmodule PidroServer.Games.RoomManagerTest do
  @moduledoc """
  Comprehensive tests for RoomManager including reconnection functionality.

  Tests cover:
  - Basic room management (create, join, leave)
  - Player disconnect handling
  - Reconnection within grace period
  - Grace period expiration and automatic cleanup
  - Multiple concurrent disconnections
  - Edge cases and error handling
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pidro.Core.Types.{Bid, Trick}
  alias PidroServer.Games.{GameAdapter, Lifecycle, RoomCodes, RoomManager}
  alias PidroServer.Games.Bots.BotBrain
  alias PidroServer.Games.Room.{Config, Positions, Seat}
  alias PidroServer.RoomFixtures

  # Note: async: false is required because RoomManager is a singleton GenServer

  setup do
    # Start the RoomManager if not already started
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    # Reset state between tests
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    :ok
  end

  describe "create_room/2" do
    test "creates a new room with host as first player" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Test Room"})

      assert room.code != nil
      assert String.length(room.code) == 4
      assert room.host_id == "user1"
      assert Positions.player_ids(room) == ["user1"]
      assert room.status == :waiting
      assert room.max_players == 4
      assert room.config.name == "Test Room"
    end

    test "prevents creating room if already in another room" do
      {:ok, _room} = RoomManager.create_room("user1", %{})

      assert {:error, :already_in_room} = RoomManager.create_room("user1", %{})
    end

    test "generates unique room codes" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})

      assert room1.code != room2.code
    end

    test "create_room/1 stores the default config" do
      {:ok, room} = RoomManager.create_room("user1")

      assert room.config == %Config{name: nil, bot_difficulty: :basic, solo: false}
      assert {:ok, %{config: %Config{name: nil}}} = RoomManager.get_room(room.code)
    end

    test "a bare name lands in the config with the default difficulty and not solo" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Friday"})

      assert room.config == %Config{name: "Friday", bot_difficulty: :basic, solo: false}
    end

    test "accepts a config struct and keyword attributes" do
      {:ok, config} = Config.new(name: "Built", bot_difficulty: :smart)

      assert {:ok, %{config: ^config}} = RoomManager.create_room("user1", config)

      assert {:ok, %{config: %Config{bot_difficulty: :random, solo: true}}} =
               RoomManager.create_room("user2", bot_difficulty: "random", solo: true)
    end

    test "rejects an unknown attribute and creates no room" do
      assert {:error, {:invalid_room_params, [%{field: "is_dev_room", message: message}]}} =
               RoomManager.create_room("user1", %{name: "Dev", is_dev_room: true})

      assert message == "is not an accepted field"
      assert RoomManager.list_rooms(:all) == []
      assert {:error, :not_in_room} = RoomManager.leave_room("user1")
    end

    test "a rejected create does not evict the caller's held seat in another room" do
      {room_a, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      :ok = RoomManager.handle_player_disconnect(room_a.code, host)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      assert {:error, {:invalid_room_params, [%{field: "mode"}]}} =
               RoomManager.create_room(host, %{mode: "competitive"})

      # The stale-room eviction lives in the GenServer handler; a rejected
      # request never reaches it, so the old room and its mapping survive.
      assert {:ok, room_a_after} = RoomManager.get_room(room_a.code)
      assert room_a_after.host_id == host
      assert Positions.has_player?(room_a_after, host)
      refute_receive {:room_closed, _code}, 100
      assert length(RoomManager.list_rooms(:all)) == 1
    end
  end

  describe "bot personas" do
    test "seeded rooms vary the partner and reproduce the crew through both seating paths" do
      crews =
        for seed <- 1..60 do
          for path <- [:join, :seat_picker] do
            host = "host_#{seed}_#{path}"
            {:ok, room} = RoomManager.create_room(host, %{}, seed: seed)

            for position <- [:east, :south, :west] do
              case path do
                :join ->
                  assert {:ok, _, ^position} =
                           RoomManager.join_bot(
                             room.code,
                             "bot_#{room.code}_#{position}",
                             self(),
                             position
                           )

                :seat_picker ->
                  assert {:ok, _} = RoomManager.set_seat(room.code, host, position, :bot)
              end
            end

            {:ok, seated} = RoomManager.get_room(room.code)
            crew = Enum.map([:east, :south, :west], &seated.seats[&1].bot_persona)
            assert Enum.sort(crew) == ~w(antti jocke marcel)
            crew
          end
          |> then(fn [joined, picked] ->
            assert joined == picked
            joined
          end)
        end

      assert crews |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq() |> Enum.sort() ==
               ~w(antti jocke marcel)

      assert length(Enum.uniq(crews)) == 6
    end

    test "a bot keeps its persona when another bot leaves and a new one joins" do
      {:ok, room} = RoomManager.create_room("host", %{name: "Crew"})

      for position <- [:east, :south] do
        assert {:ok, _, ^position} =
                 RoomManager.join_bot(room.code, "bot_#{room.code}_#{position}", self(), position)
      end

      assert {:ok, before} = RoomManager.get_room(room.code)
      east_persona = before.seats.east.bot_persona
      south_persona = before.seats.south.bot_persona
      refute east_persona == south_persona

      assert :ok = RoomManager.leave_room("bot_#{room.code}_east")

      assert {:ok, _, :west} =
               RoomManager.join_bot(room.code, "bot_#{room.code}_west", self(), :west)

      assert {:ok, %{seats: seats}} = RoomManager.get_room(room.code)
      assert seats.east.occupant_type == :vacant
      assert seats.east.bot_persona == nil
      assert seats.south.bot_persona == south_persona
      assert seats.west.bot_persona == east_persona
    end
  end

  describe "create_room/2 room code allocation" do
    # The :create_room handler reads an optional generator override from the
    # app env at call time so collisions can be forced deterministically.
    setup do
      original = Application.get_env(:pidro_server, RoomCodes)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pidro_server, RoomCodes, original),
          else: Application.delete_env(:pidro_server, RoomCodes)
      end)

      :ok
    end

    test "retries a colliding code and leaves the existing room untouched" do
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ZZZZ" end)
      {:ok, %{code: "ZZZZ"}} = RoomManager.create_room("user1", %{name: "First"})
      {:ok, _room, _position} = RoomManager.join_room("ZZZZ", "user2")

      Application.put_env(:pidro_server, RoomCodes,
        generator: sequence_generator(["ZZZZ", "YYYY"])
      )

      assert {:ok, %{code: "YYYY", host_id: "user3"}} = RoomManager.create_room("user3", %{})

      assert {:ok, existing} = RoomManager.get_room("ZZZZ")
      assert existing.host_id == "user1"
      assert Enum.sort(Positions.player_ids(existing)) == ["user1", "user2"]
      assert existing.config.name == "First"
    end

    test "replies :room_code_exhausted after 10 collisions and keeps the colliding room intact" do
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ZZZZ" end)
      {:ok, %{code: "ZZZZ"}} = RoomManager.create_room("user1", %{name: "First"})
      {:ok, _room, _position} = RoomManager.join_room("ZZZZ", "user2")

      calls = :counters.new(1, [])

      Application.put_env(:pidro_server, RoomCodes,
        generator: fn ->
          :counters.add(calls, 1, 1)
          "ZZZZ"
        end
      )

      log =
        capture_log([level: :error], fn ->
          assert {:error, :room_code_exhausted} = RoomManager.create_room("user3", %{})
        end)

      assert :counters.get(calls, 1) == 10
      assert log =~ "live rooms: 1"

      assert {:ok, existing} = RoomManager.get_room("ZZZZ")
      assert existing.host_id == "user1"
      assert Enum.sort(Positions.player_ids(existing)) == ["user1", "user2"]
      assert existing.config.name == "First"
      assert length(RoomManager.list_rooms(:all)) == 1

      # The failed host was never tracked, so a later attempt with a free code succeeds
      Application.delete_env(:pidro_server, RoomCodes)
      assert {:ok, %{host_id: "user3"}} = RoomManager.create_room("user3", %{})
    end

    test "get_room/1 finds a room by its lowercased code" do
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ABCD" end)
      {:ok, %{code: "ABCD"}} = RoomManager.create_room("user1", %{})

      assert {:ok, %{code: "ABCD"}} = RoomManager.get_room("abcd")
    end
  end

  describe "join_room/2" do
    test "allows player to join existing room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, updated_room, _} = RoomManager.join_room(room.code, "user2")

      assert Positions.has_player?(updated_room, "user1") &&
               Positions.has_player?(updated_room, "user2") && Positions.count(updated_room) == 2

      assert updated_room.status == :waiting
    end

    test "prevents player from joining if already in another room" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})

      {:ok, _, _} = RoomManager.join_room(room1.code, "user3")

      assert {:error, :already_in_room} = RoomManager.join_room(room2.code, "user3")
    end

    test "prevents joining non-existent room" do
      assert {:error, :room_not_found} = RoomManager.join_room("ZZZZ", "user1")
    end

    test "prevents joining full room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")

      assert {:error, :room_full} = RoomManager.join_room(room.code, "user5")
    end

    test "stays waiting when 4th player joins" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, final_room, _} = RoomManager.join_room(room.code, "user4")

      assert final_room.status == :waiting
      assert Positions.count(final_room) == 4
    end

    test "handles case-insensitive room codes" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      lowercase_code = String.downcase(room.code)

      {:ok, updated_room, _} = RoomManager.join_room(lowercase_code, "user2")

      assert updated_room.code == room.code
    end
  end

  describe "leave_room/2" do
    test "leaves the named room when the player is in it, in any case" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.leave_room(String.downcase(room.code), "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.player_ids(updated_room) == ["user1"]
    end

    test "leaves nothing when the player has moved on to another room" do
      {:ok, finished} = RoomManager.create_room("other", %{})
      {:ok, _, _} = RoomManager.join_room(finished.code, "user1")
      :ok = RoomManager.update_room_status(finished.code, :finished)
      :ok = RoomManager.leave_room("user1")
      {:ok, room} = RoomManager.create_room("user1", %{solo: true})

      assert {:error, :not_in_room} = RoomManager.leave_room(finished.code, "user1")
      assert {:ok, %{host_id: "user1"}} = RoomManager.get_room(room.code)
      assert :sys.get_state(RoomManager).player_rooms["user1"] == room.code
    end

    test "returns error when player is in no room" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      assert {:error, :not_in_room} = RoomManager.leave_room(room.code, "nobody")
    end
  end

  describe "leave_room/1" do
    test "removes player from room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.leave_room("user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.player_ids(updated_room) == ["user1"]
      assert Positions.count(updated_room) == 1
    end

    test "closes room when host leaves" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.leave_room("user1")

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "deletes room when last player leaves" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      :ok = RoomManager.leave_room("user1")

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "returns error when player not in room" do
      assert {:error, :not_in_room} = RoomManager.leave_room("nonexistent")
    end

    test "keeps a pre-start room waiting when a player leaves" do
      {room, _players} = RoomFixtures.waiting_room_fixture(seated: 3)

      :ok = RoomManager.leave_room("user3")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert updated_room.status == :waiting
      assert Positions.count(updated_room) == 2
      assert updated_room.seats.south.occupant_type == :vacant
    end

    test "closes a single-player table when the human leaves mid-game" do
      {:ok, room} = RoomManager.create_room("user1", %{solo: true})
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-east")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-south")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-west")
      RoomFixtures.ready_room(room.code)

      wait_until(fn ->
        case RoomManager.get_room(room.code) do
          {:ok, %{status: :playing}} -> true
          _ -> false
        end
      end)

      :ok = RoomManager.leave_room("user1")

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end
  end

  describe "handle_player_disconnect/2" do
    test "holds the seat of a waiting-room disconnect without a phase timer" do
      {room, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      before_disconnect = DateTime.utc_now()
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, held_room} = RoomManager.get_room(room.code)

      assert held_room.status == :waiting
      assert Positions.has_player?(held_room, "user2")

      assert %Seat{
               status: :reconnecting,
               occupant_type: :human,
               user_id: "user2",
               disconnected_at: %DateTime{}
             } = held_room.seats[:east]

      assert held_room.phase_timers == %{}
      assert DateTime.compare(held_room.last_activity, before_disconnect) in [:gt, :eq]
      assert_receive {:player_reconnecting, %{user_id: "user2", position: :east}}, 100

      # No cascade: past the hiccup timeout the seat is still held and no bot exists.
      Process.sleep(Lifecycle.config(:hiccup_timeout_ms) + 50)

      {:ok, later_room} = RoomManager.get_room(room.code)

      assert %Seat{status: :reconnecting, occupant_type: :human, bot_pid: nil} =
               later_room.seats[:east]

      assert later_room.phase_timers == %{}
      refute_received {:bot_substitute_active, _}
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} =
               RoomManager.handle_player_disconnect("ZZZZ", "user1")
    end

    test "returns error when player not in room" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      assert {:error, :player_not_in_room} =
               RoomManager.handle_player_disconnect(room.code, "user999")
    end

    test "a second disconnect of a held seat leaves the hold unchanged" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()

      :ok = RoomManager.handle_player_disconnect(room.code, host)
      {:ok, %{seats: %{north: %Seat{disconnected_at: held_at}}}} = RoomManager.get_room(room.code)

      :ok = RoomManager.handle_player_disconnect(room.code, host)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(updated_room, host)
      assert %Seat{status: :reconnecting, disconnected_at: ^held_at} = updated_room.seats[:north]
    end

    test "holds every disconnected seat independently" do
      {room, [host, "user2", "user3"]} = RoomFixtures.waiting_room_fixture(seated: 3)

      :ok = RoomManager.handle_player_disconnect(room.code, host)
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert Positions.player_ids(updated_room) == [host, "user2", "user3"]
      assert updated_room.seats[:north].status == :reconnecting
      assert updated_room.seats[:east].status == :reconnecting
      assert Seat.connected_human?(updated_room.seats[:south])
    end

    test "single-player room holds the human seat without an expiry timer" do
      {:ok, room} = RoomManager.create_room("user1", %{solo: true})
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-east")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-south")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-west")
      RoomFixtures.ready_room(room.code)

      wait_until(fn ->
        case RoomManager.get_room(room.code) do
          {:ok, %{status: :playing}} -> true
          _ -> false
        end
      end)

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      # Room stays alive and holds the human seat instead of surrendering it.
      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert updated_room.status == :playing

      position = Positions.get_position(updated_room, "user1")
      seat = Map.get(updated_room.seats, position)
      assert seat.status == :reconnecting
      assert seat.occupant_type == :human
      assert seat.user_id == "user1"
      assert seat.grace_expires_at == nil
      assert updated_room.phase_timers[position] == nil

      # Stale cascade messages cannot replace a held solo seat.
      stale_ref = make_ref()
      send(RoomManager, {:timeout, stale_ref, {:phase2_start, room.code, position}})
      send(RoomManager, {:timeout, stale_ref, {:phase3_gone, room.code, position}})

      {:ok, still_held} = RoomManager.get_room(room.code)
      assert still_held.seats[position].status == :reconnecting
      assert still_held.seats[position].occupant_type == :human

      {:ok, reconnected} = RoomManager.handle_player_reconnect(room.code, "user1")
      assert reconnected.seats[position].status == :connected
      assert reconnected.seats[position].occupant_type == :human
    end

    test "single-player room allows reconnection after disconnect" do
      {:ok, room} = RoomManager.create_room("user1", %{solo: true})
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-east")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-south")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-west")
      RoomFixtures.ready_room(room.code)

      wait_until(fn ->
        case RoomManager.get_room(room.code) do
          {:ok, %{status: :playing}} -> true
          _ -> false
        end
      end)

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      # Reconnect within hiccup window succeeds
      {:ok, reconnected_room} = RoomManager.handle_player_reconnect(room.code, "user1")
      position = Positions.get_position(reconnected_room, "user1")
      seat = Map.get(reconnected_room.seats, position)
      assert seat.status == :connected
      assert seat.occupant_type == :human
    end

    test "intentional leave still closes single-player room immediately" do
      {:ok, room} = RoomManager.create_room("user1", %{solo: true})
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-east")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-south")
      {:ok, _, _} = RoomManager.join_room(room.code, "bot-west")
      RoomFixtures.ready_room(room.code)

      wait_until(fn ->
        case RoomManager.get_room(room.code) do
          {:ok, %{status: :playing}} -> true
          _ -> false
        end
      end)

      :ok = RoomManager.leave_room("user1")

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end
  end

  describe "handle_player_reconnect/2" do
    test "reclaims a held seat in a waiting room without starting the game" do
      {room, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      assert {:ok, reclaimed} = RoomManager.handle_player_reconnect(room.code, "user2")

      assert reclaimed.status == :waiting
      assert Seat.connected_human?(reclaimed.seats[:east])
      assert reclaimed.seats[:east].user_id == "user2"
      assert_receive {:player_reconnected, %{user_id: "user2", position: :east}}, 100
      assert {:ok, %{status: :waiting}} = RoomManager.get_room(room.code)
    end

    test "returns error when player not disconnected" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      # Try to reconnect without disconnecting first
      assert {:error, :player_not_disconnected} =
               RoomManager.handle_player_reconnect(room.code, "user2")
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} =
               RoomManager.handle_player_reconnect("ZZZZ", "user1")
    end

    # AE5: the host backgrounds the app to paste the link; the table fills
    # while the seat is held and needs fresh readiness after the host is back.
    test "a full table waits for a held host and readiness after reclaim" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()
      :ok = RoomManager.handle_player_disconnect(room.code, host)

      {:ok, _, :east} = RoomManager.join_room(room.code, "user2")
      {:ok, _, :south} = RoomManager.join_room(room.code, "user3")
      {:ok, full_room, :west} = RoomManager.join_room(room.code, "user4")

      assert Positions.count(full_room) == 4
      assert full_room.status == :waiting
      assert full_room.seats[:north].status == :reconnecting

      Process.sleep(50)
      assert {:ok, %{status: :waiting}} = RoomManager.get_room(room.code)

      assert {:ok, reclaimed} = RoomManager.handle_player_reconnect(room.code, host)

      assert Seat.connected_human?(reclaimed.seats[:north])
      assert reclaimed.status == :waiting
      RoomFixtures.ready_room(room.code)
      assert {:ok, %{status: :playing}} = RoomManager.get_room(room.code)
    end

    test "a full table starts only after every held seat is reclaimed and readied" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      :ok = RoomManager.handle_player_disconnect(room.code, host)
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, _, :south} = RoomManager.join_room(room.code, "user3")
      {:ok, %{status: :waiting}, :west} = RoomManager.join_room(room.code, "user4")

      assert {:ok, %{status: :waiting}} = RoomManager.handle_player_reconnect(room.code, host)
      assert {:ok, %{status: :waiting}} = RoomManager.handle_player_reconnect(room.code, "user2")
      assert RoomFixtures.ready_room(room.code).status == :playing
    end
  end

  describe "held seats have no expiry" do
    test "a held seat outlives the hiccup and grace timeouts without a bot" do
      {room, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      Process.sleep(Lifecycle.config(:grace_timeout_ms) + 50)

      {:ok, final_room} = RoomManager.get_room(room.code)
      assert final_room.status == :waiting
      assert Positions.has_player?(final_room, "user2")

      assert %Seat{status: :reconnecting, occupant_type: :human, bot_pid: nil, reserved_for: nil} =
               final_room.seats[:east]

      refute_received {:bot_substitute_active, _}
      refute_received {:seat_permanently_botted, _}
    end

    test "several held seats stay held together" do
      {room, [_host, "user2", "user3"]} = RoomFixtures.waiting_room_fixture(seated: 3)

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      Process.sleep(Lifecycle.config(:grace_timeout_ms) + 50)

      {:ok, final_room} = RoomManager.get_room(room.code)
      assert final_room.status == :waiting
      assert final_room.seats[:east].status == :reconnecting
      assert final_room.seats[:south].status == :reconnecting
      assert final_room.phase_timers == %{}
    end
  end

  describe "disconnect timeout and grace period" do
    test "multiple disconnected players stay in a playing room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")

      # Disconnect players at slightly different times
      RoomFixtures.ready_room(room.code)
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      Process.sleep(10)
      :ok = RoomManager.handle_player_disconnect(room.code, "user3")

      # Wait past the hiccup timeout: the cascade substitutes bots but keeps
      # the positions reserved for the disconnected players.
      Process.sleep(100)

      {:ok, final_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(final_room, "user1")
      assert Positions.has_player?(final_room, "user2")
      assert Positions.has_player?(final_room, "user3")
      assert Positions.has_player?(final_room, "user4")
    end

    test "grace period check handles room that no longer exists" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      # Host leaves, closing the room
      :ok = RoomManager.leave_room("user1")

      # Wait for grace period - should not crash
      Process.sleep(100)

      # Room should still not exist
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end
  end

  describe "list_rooms/1" do
    test "lists all rooms by default" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})

      rooms = RoomManager.list_rooms()

      assert length(rooms) == 2
      codes = Enum.map(rooms, & &1.code)
      assert room1.code in codes
      assert room2.code in codes
    end

    test "filters rooms by status" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})
      {:ok, _, _} = RoomManager.join_room(room2.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room2.code, "user4")
      {:ok, _, _} = RoomManager.join_room(room2.code, "user5")
      RoomFixtures.ready_room(room2.code)

      waiting_rooms = RoomManager.list_rooms(:waiting)
      playing_rooms = RoomManager.list_rooms(:playing)

      assert length(waiting_rooms) == 1
      assert hd(waiting_rooms).code == room1.code

      # When 4th player joins, room transitions to :ready and immediately to :playing
      # because GameSupervisor auto-starts the game
      assert length(playing_rooms) == 1
      assert hd(playing_rooms).code == room2.code
    end

    test "returns empty list when no rooms exist" do
      rooms = RoomManager.list_rooms()
      assert rooms == []
    end
  end

  describe "get_room/1" do
    test "retrieves room by code" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Test"})

      {:ok, fetched_room} = RoomManager.get_room(room.code)

      assert fetched_room.code == room.code
      assert fetched_room.host_id == "user1"
      assert fetched_room.config.name == "Test"
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} = RoomManager.get_room("ZZZZ")
    end

    test "handles case-insensitive lookup" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      lowercase_code = String.downcase(room.code)

      {:ok, fetched_room} = RoomManager.get_room(lowercase_code)

      assert fetched_room.code == room.code
    end
  end

  describe "update_room_status/2" do
    test "updates room status" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      :ok = RoomManager.update_room_status(room.code, :playing)

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert updated_room.status == :playing
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} =
               RoomManager.update_room_status("ZZZZ", :playing)
    end

    test "allows all valid status transitions" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      for status <- [:waiting, :ready, :playing, :finished, :closed] do
        :ok = RoomManager.update_room_status(room.code, status)
        {:ok, updated_room} = RoomManager.get_room(room.code)
        assert updated_room.status == status
      end
    end
  end

  describe "close_room/1" do
    test "closes and removes room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.close_room(room.code)

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "removes all player mappings when closing room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.close_room(room.code)

      # Players should be able to join new rooms
      {:ok, new_room} = RoomManager.create_room("user1", %{})
      assert new_room.host_id == "user1"
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} = RoomManager.close_room("ZZZZ")
    end
  end

  describe "edge cases and concurrent operations" do
    test "disconnect and leave are idempotent for same player" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")
      :ok = RoomManager.leave_room("user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      refute Positions.has_player?(updated_room, "user2")
    end

    test "handles room state correctly after disconnect in waiting room" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")

      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)

      # Still 3 players: a waiting-room disconnect holds the seat, it does not free it.
      assert Positions.count(updated_room) == 3
      assert updated_room.seats[:east].status == :reconnecting
      assert updated_room.status == :waiting
    end

    test "reconnect after disconnect in waiting room reclaims the held seat" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      :ok = RoomManager.handle_player_disconnect(room.code, "user1")

      assert {:ok, reclaimed} = RoomManager.handle_player_reconnect(room.code, "user1")
      assert Seat.connected_human?(reclaimed.seats[:north])

      assert {:error, :player_not_disconnected} =
               RoomManager.handle_player_reconnect(room.code, "user1")

      {:ok, final_room} = RoomManager.get_room(room.code)
      assert Positions.has_player?(final_room, "user1")
    end
  end

  describe "held seats when the player moves to another room" do
    test "a held host who creates another room closes the old room" do
      {room_a, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      :ok = RoomManager.handle_player_disconnect(room_a.code, host)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      assert {:ok, room_b} = RoomManager.create_room(host, %{})

      assert room_b.code != room_a.code
      assert {:error, :room_not_found} = RoomManager.get_room(room_a.code)
      assert_receive {:room_closed, closed_code}, 100
      assert closed_code == room_a.code

      # user2 is free to sit elsewhere: the closed room dropped its mappings.
      assert {:ok, _room, _position} = RoomManager.join_room(room_b.code, "user2")
    end

    test "a held player who joins another room by code has the old seat vacated" do
      {room_a, [_host_a, "user2"]} =
        RoomFixtures.waiting_room_fixture(host_id: "host-a", seated: 2)

      {room_b, _ids} = RoomFixtures.waiting_room_fixture(host_id: "host-b", prefix: "b")
      :ok = RoomManager.handle_player_disconnect(room_a.code, "user2")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room_a.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      assert {:ok, seated_b, :east} = RoomManager.join_room(room_b.code, "user2")
      assert Seat.connected_human?(seated_b.seats[:east])

      {:ok, room_a_after} = RoomManager.get_room(room_a.code)
      assert room_a_after.status == :waiting
      assert room_a_after.positions[:east] == nil
      assert Seat.vacant?(room_a_after.seats[:east])
      assert_receive {:room_update, %{positions: %{east: nil}}}, 100
      assert_receive {:room_updated, %{positions: %{east: nil}}}, 100

      # The caller is now tracked in room B only.
      :ok = RoomManager.leave_room("user2")
      assert {:ok, %{positions: %{east: nil}}} = RoomManager.get_room(room_b.code)
    end

    test "a held player who creates another room is removed from the old room's position" do
      {room_a, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      :ok = RoomManager.handle_player_disconnect(room_a.code, "user2")

      assert {:ok, _room_b} = RoomManager.create_room("user2", %{})

      {:ok, room_a_after} = RoomManager.get_room(room_a.code)
      refute Positions.has_player?(room_a_after, "user2")
      assert Seat.vacant?(room_a_after.seats[:east])
    end

    test "the old room closes when vacating the held seat empties it" do
      {room_a, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      # The dev helper rebuilds every seat, so clear the host before holding user2's seat.
      {:ok, _} = RoomManager.dev_set_position(room_a.code, :north, nil)
      :ok = RoomManager.handle_player_disconnect(room_a.code, "user2")

      assert {:ok, _room_b} = RoomManager.create_room("user2", %{})

      assert {:error, :room_not_found} = RoomManager.get_room(room_a.code)
    end

    test "a connected seat is not vacated" do
      {room_a, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      {room_b, _ids} = RoomFixtures.waiting_room_fixture(host_id: "host-b", prefix: "b")

      assert {:error, :already_in_room} = RoomManager.join_room(room_b.code, "user2")
      assert {:ok, %{positions: %{east: "user2"}}} = RoomManager.get_room(room_a.code)
    end

    test "a failed target join keeps the caller's held seat" do
      {room_a, [_host_a, "user2"]} =
        RoomFixtures.waiting_room_fixture(host_id: "host-a", seated: 2)

      {room_b, [host_b, _user_b]} =
        RoomFixtures.waiting_room_fixture(host_id: "host-b", prefix: "b", seated: 2)

      :ok = RoomManager.handle_player_disconnect(room_a.code, "user2")
      {:ok, _locked} = RoomManager.set_locked(room_b.code, host_b, true)

      assert {:error, :table_locked} = RoomManager.join_room(room_b.code, "user2")

      assert {:ok, room_a_after} = RoomManager.get_room(room_a.code)
      assert room_a_after.positions[:east] == "user2"
      assert room_a_after.seats[:east].status == :reconnecting
    end

    test "a failed explicit invite claim keeps the caller's held seat" do
      {room_a, [_host_a, "user2"]} =
        RoomFixtures.waiting_room_fixture(host_id: "host-a", seated: 2)

      {room_b, [_host_b]} = RoomFixtures.waiting_room_fixture(host_id: "host-b", prefix: "b")
      :ok = RoomManager.handle_player_disconnect(room_a.code, "user2")

      assert {:error, {:seat_taken, _open}} =
               RoomManager.claim_seat(room_b.code, room_b.id, "user2", position: :north)

      assert {:ok, room_a_after} = RoomManager.get_room(room_a.code)
      assert room_a_after.positions[:east] == "user2"
      assert room_a_after.seats[:east].status == :reconnecting
    end

    test "a :playing room keeps the cascade when the disconnected player creates another room" do
      room_code = create_playing_room()
      :ok = RoomManager.handle_player_disconnect(room_code, "user2")

      assert {:ok, _room_b} = RoomManager.create_room("user2", %{})

      {:ok, playing_room} = RoomManager.get_room(room_code)
      assert playing_room.status == :playing
      assert playing_room.positions[:east] == "user2"
      assert playing_room.seats[:east].status == :reconnecting
      assert Map.has_key?(playing_room.phase_timers, :east)
    end
  end

  describe "last_activity tracking" do
    test "initializes last_activity on room creation" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Test Room"})
      assert room.last_activity != nil
      assert DateTime.diff(DateTime.utc_now(), room.last_activity, :second) < 2
    end

    test "updates last_activity on player join" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      original_activity = room.last_activity

      Process.sleep(100)
      {:ok, updated_room, _} = RoomManager.join_room(room.code, "user2")

      assert DateTime.compare(updated_room.last_activity, original_activity) == :gt
    end

    test "updates last_activity on player disconnect" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, room_before} = RoomManager.get_room(room.code)

      Process.sleep(100)
      :ok = RoomManager.handle_player_disconnect(room.code, "user2")

      {:ok, updated_room} = RoomManager.get_room(room.code)
      assert DateTime.compare(updated_room.last_activity, room_before.last_activity) == :gt
    end
  end

  describe "turn timers" do
    test "does not start turn timers for single-player rooms" do
      room_code = create_playing_room(%{solo: true})
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      _bidding_state = advance_room_to_bidding(room_code)

      assert {:ok, nil} = RoomManager.get_turn_timer(room_code)
      refute_receive {:turn_timer_started, _payload}, 100
    end

    test "starts a room-owned timer for all-human dealer selection" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      room_code = room.code

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      {:ok, _, _} = RoomManager.join_room(room_code, "user2")
      {:ok, _, _} = RoomManager.join_room(room_code, "user3")
      {:ok, _, _} = RoomManager.join_room(room_code, "user4")

      RoomFixtures.ready_room(room_code)
      assert_receive {:turn_timer_started, payload}, 200
      assert payload.scope == :room
      assert payload.position == nil
      assert payload.phase == :dealer_selection
      assert payload.transition_delay_ms == 0
      assert payload.event_seq == 0

      turn_timer = wait_for_turn_timer(room_code)
      assert turn_timer.scope == :room
      assert turn_timer.position == nil
      assert turn_timer.phase == :dealer_selection
      assert turn_timer.timer_id == payload.timer_id
      assert turn_timer.remaining_ms > 0
    end

    test "restarts the timer when a new same-position action window arrives" do
      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      active_timer = wait_for_turn_timer(room_code)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      send(
        RoomManager,
        {:state_update, room_code,
         %{
           state: %{bidding_state | events: bidding_state.events ++ [:synthetic_window]},
           transition_delay_ms: 0
         }}
      )

      assert_receive {:turn_timer_cancelled, cancelled}, 200
      assert cancelled.timer_id == active_timer.timer_id
      assert cancelled.position == active_timer.position
      assert cancelled.reason == :acted

      assert_receive {:turn_timer_started, started}, 200
      assert started.scope == :seat
      assert started.position == active_timer.position
      assert started.phase == active_timer.phase
      assert started.event_seq == active_timer.event_seq + 1
      assert started.timer_id != active_timer.timer_id
    end

    test "does not reconcile an already accepted game-state revision twice" do
      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      _active_timer = wait_for_turn_timer(room_code)
      {:ok, snapshot} = GameAdapter.get_snapshot(room_code)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      payload =
        snapshot
        |> Map.put(:state, %{bidding_state | events: bidding_state.events ++ [:new_window]})
        |> Map.put(:state_revision, snapshot.state_revision + 1)
        |> Map.put(:transition_delay_ms, 0)

      send(RoomManager, {:state_update, room_code, payload})

      assert_receive {:turn_timer_cancelled, %{reason: :acted}}, 200
      assert_receive {:turn_timer_started, _accepted}, 200

      send(RoomManager, {:state_update, room_code, payload})

      refute_receive {:turn_timer_cancelled, _}, 100
      refute_receive {:turn_timer_started, _}, 100
    end

    test "rejects a queued snapshot from a replaced game instance" do
      original = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.put(original, :turn_timer_bid_ms, 10_000)
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, original) end)

      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      _active_timer = wait_for_turn_timer(room_code)
      {:ok, snapshot} = GameAdapter.get_snapshot(room_code)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      stale_payload =
        snapshot
        |> Map.put(:game_instance_id, "retired-game-instance")
        |> Map.put(:state, %{bidding_state | events: bidding_state.events ++ [:stale_window]})
        |> Map.put(:state_revision, snapshot.state_revision + 100)
        |> Map.put(:transition_delay_ms, 0)

      manager_before = :sys.get_state(RoomManager)
      send(RoomManager, {:state_update, room_code, stale_payload})

      refute_receive {:turn_timer_cancelled, _}, 100
      refute_receive {:turn_timer_started, _}, 100

      manager_after = :sys.get_state(RoomManager)
      assert manager_after.game_snapshot_cursors == manager_before.game_snapshot_cursors

      assert manager_after.rooms[room_code].turn_timer.timer_id ==
               manager_before.rooms[room_code].turn_timer.timer_id
    end

    test "disconnect pauses the active deadline and reconnect resumes its remaining time" do
      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      wait_for_turn_timer(room_code)
      {:ok, room} = RoomManager.get_room(room_code)
      timed_user = Map.fetch!(room.positions, bidding_state.current_turn)
      timer = room.turn_timer
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")
      :ok = RoomManager.handle_player_disconnect(room_code, timed_user)

      {:ok, disconnected} = RoomManager.get_room(room_code)
      assert disconnected.seats[bidding_state.current_turn].status == :reconnecting
      assert disconnected.turn_timer == nil
      assert Process.read_timer(timer.ref) == false
      assert_receive {:turn_timer_cancelled, %{reason: :disconnected}}
      refute_receive {:turn_timer_started, _}, 20

      # A queued expiry for the replaced timer cannot act on this window.
      send(RoomManager, {:turn_timer_expired, room_code, timer.timer_id, timer.key})
      {:ok, unchanged} = RoomManager.get_room(room_code)
      assert unchanged.turn_timer == nil
      assert {:ok, reconnected} = RoomManager.handle_player_reconnect(room_code, timed_user)
      assert reconnected.turn_timer.key == timer.key
      assert reconnected.turn_timer.timer_id != timer.timer_id

      assert reconnected.turn_timer.duration_ms ==
               max(disconnected.paused_turn.remaining_ms, 10_000)

      assert_receive {:turn_timer_started, _}
    end

    test "off-turn disconnect does not change the active deadline" do
      room_code = create_playing_room()
      bidding = advance_room_to_bidding(room_code)
      wait_for_turn_timer(room_code)
      {:ok, room} = RoomManager.get_room(room_code)
      {_, user} = Enum.find(room.positions, fn {pos, _} -> pos != bidding.current_turn end)
      :ok = RoomManager.handle_player_disconnect(room_code, user)
      {:ok, disconnected} = RoomManager.get_room(room_code)
      assert disconnected.turn_timer == room.turn_timer
    end

    test "a queued turn expiry cannot auto-play while reconnecting" do
      room_code = create_playing_room()
      bidding = advance_room_to_bidding(room_code)
      wait_for_turn_timer(room_code)
      {:ok, room} = RoomManager.get_room(room_code)
      user = room.positions[bidding.current_turn]
      timer = room.turn_timer
      :ok = RoomManager.handle_player_disconnect(room_code, user)
      {:ok, disconnected} = RoomManager.get_room(room_code)
      assert disconnected.turn_timer == nil
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")
      send(RoomManager, {:turn_timer_expired, room_code, timer.timer_id, timer.key})
      refute_receive {:turn_auto_played, _}, 20
      {:ok, game} = GameAdapter.get_state(room_code)
      assert game.events == bidding.events
    end

    test "reconciles the action window on reconnect when no timer survives" do
      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      {:ok, room} = RoomManager.get_room(room_code)

      timed_position = bidding_state.current_turn
      timed_user = Map.fetch!(room.positions, timed_position)

      :ok = RoomManager.handle_player_disconnect(room_code, timed_user)

      :sys.replace_state(RoomManager, fn %RoomManager.State{} = manager_state ->
        current_room = Map.fetch!(manager_state.rooms, room_code)
        PidroServer.Games.TurnTimer.cancel_timer(current_room.turn_timer)
        updated_room = %{current_room | turn_timer: nil}
        %{manager_state | rooms: Map.put(manager_state.rooms, room_code, updated_room)}
      end)

      assert {:ok, nil} = RoomManager.get_turn_timer(room_code)
      assert {:ok, _room} = RoomManager.handle_player_reconnect(room_code, timed_user)

      resumed_timer = wait_for_turn_timer(room_code)

      assert resumed_timer.scope == :seat
      assert resumed_timer.position == timed_position
      assert resumed_timer.phase == :bidding
      assert resumed_timer.event_seq == length(bidding_state.events)
      assert resumed_timer.remaining_ms > 0
    end

    test "uses the disconnect fallback when a timed-out player has no live game channel pid" do
      room_code = create_playing_room()
      bidding_state = advance_room_to_bidding(room_code)
      {:ok, room} = RoomManager.get_room(room_code)
      timer = wait_for_turn_timer(room_code)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      position = bidding_state.current_turn
      threshold = Lifecycle.config(:consecutive_timeout_threshold)
      timed_user = Map.fetch!(room.positions, position)

      :sys.replace_state(RoomManager, fn %RoomManager.State{} = manager_state ->
        current_room = Map.fetch!(manager_state.rooms, room_code)
        updated_room = %{current_room | consecutive_timeouts: %{position => threshold - 1}}
        # Exercise the fallback with no routable channel, rather than the
        # synthetic channel used to complete the pregame readiness handshake.
        %{
          manager_state
          | rooms: Map.put(manager_state.rooms, room_code, updated_room),
            channel_pids: Map.delete(manager_state.channel_pids, {room_code, timed_user})
        }
      end)

      send(
        RoomManager,
        {:turn_timer_expired, room_code, timer.timer_id,
         {:seat, timer.position, timer.phase, timer.event_seq}}
      )

      assert_receive {:turn_auto_played, payload}, 200
      assert payload.scope == :seat
      assert payload.position == position
      assert payload.phase == :bidding
      assert payload.action == %{type: :pass}

      updated_room =
        wait_until(fn ->
          case RoomManager.get_room(room_code) do
            {:ok, %{seats: %{^position => seat}} = updated_room}
            when seat.status == :reconnecting ->
              updated_room

            _ ->
              nil
          end
        end)

      assert updated_room.consecutive_timeouts[position] == threshold
      assert updated_room.seats[position].user_id == timed_user
    end

    test "ignores stale timeout messages" do
      room_code = create_playing_room()
      _bidding_state = advance_room_to_bidding(room_code)
      timer = wait_for_turn_timer(room_code)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      send(
        RoomManager,
        {:turn_timer_expired, room_code, timer.timer_id + 1_000,
         {:seat, timer.position, timer.phase, timer.event_seq}}
      )

      refute_receive {:turn_auto_played, _payload}, 50

      {:ok, current_timer} = RoomManager.get_turn_timer(room_code)
      assert current_timer.timer_id == timer.timer_id
      assert current_timer.position == timer.position
      assert current_timer.phase == timer.phase
      assert current_timer.event_seq == timer.event_seq
    end
  end

  describe "settled hand" do
    setup do
      previous = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(previous,
          trick_transition_delay_ms: 0,
          bot_delay_ms: 300,
          settle_presentation_ms: 700
        )
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, previous) end)
    end

    test "a lone trump holder lays the rest down in one step, a bot beat after the last real trick" do
      room_code = create_playing_room()
      {:ok, pid} = GameAdapter.get_game(room_code)
      :ok = GenServer.call(pid, {:set_state, west_about_to_go_cold()})
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      {:ok, _} = GameAdapter.apply_action(room_code, :west, {:play_card, {4, :hearts}})

      # West's last trump completes an ordinary trick, and west is still in.
      {_, after_last_trump} = receive_state_update()
      refute after_last_trump.state.players.west.eliminated?

      # South leads the next trick on an ordinary turn; west goes out on theirs.
      assert_receive {:turn_timer_started, %{position: :south, phase: :playing}}, 1_000
      {:ok, _} = GameAdapter.apply_action(room_code, :south, {:play_card, {14, :hearts}})

      {west_out_at, west_out} = receive_state_update()
      assert west_out.state.players.west.eliminated?
      assert west_out.state.current_trick == nil
      turns = :sys.get_state(RoomManager).rooms[room_code].table_outcome.turns

      # South's last three go down together, in the next revision.
      {settled_at, settled} = receive_state_update()
      refute_receive {:state_update, _, _}, 200

      # Measured on receipt, so the bounds allow delivery jitter; the beat,
      # not the lay-down hold (700).
      assert (settled_at - west_out_at) in 280..600
      assert settled.state_revision == west_out.state_revision + 1
      assert settled.state.hand_number == 2

      assert settled.state.last_hand.settled == %{
               position: :south,
               cards: [{10, :hearts}, {5, :hearts}, {2, :hearts}]
             }

      assert settled.state.cumulative_scores == %{north_south: 8, east_west: 1}

      assert for({:card_played, :south, card} <- settled.state.events, do: card) ==
               [{14, :hearts}, {10, :hearts}, {5, :hearts}, {2, :hearts}]

      # The next deal waits for the lay-down as well as the hand's result.
      assert settled.transition_delay_ms ==
               700 + Lifecycle.config(:hand_transition_delay_ms) +
                 Lifecycle.config(:deal_transition_delay_ms)

      refute_received {:turn_timer_started, %{position: :south, phase: :playing}}

      # The table's stats count one turn per card laid, as for any card played.
      assert :sys.get_state(RoomManager).rooms[room_code].table_outcome.turns == turns + 3
    end

    test "the holder's own card during the beat wins over the settlement" do
      room_code = create_playing_room()
      {:ok, pid} = GameAdapter.get_game(room_code)

      {:ok, last_trump} =
        Pidro.Game.Engine.apply_action(west_about_to_go_cold(), :west, {:play_card, {4, :hearts}})

      :ok = GenServer.call(pid, {:set_state, last_trump})
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")

      {:ok, _} = GameAdapter.apply_action(room_code, :south, {:play_card, {14, :hearts}})
      {_, west_out} = receive_state_update()
      assert {:south, _} = Pidro.Game.Play.settled_play(west_out.state)

      # Inside the beat, south taps their ten: an ordinary one-card trick.
      Process.sleep(100)
      {:ok, _} = GameAdapter.apply_action(room_code, :south, {:play_card, {10, :hearts}})
      {tapped_at, tapped} = receive_state_update()
      assert tapped.state.hand_number == 1

      # The beat starts again from the tap; only the rest is laid down.
      {settled_at, settled} = receive_state_update()
      refute_receive {:state_update, _, _}, 400
      assert (settled_at - tapped_at) in 280..600
      assert settled.state.last_hand.settled.cards == [{5, :hearts}, {2, :hearts}]

      assert for({:hand_settled, _, _} = event <- settled.state.events, do: event) ==
               [{:hand_settled, :south, [{5, :hearts}, {2, :hearts}]}]
    end

    test "a bot holding the last trumps leaves them to the settlement once the others are out" do
      {:ok, last_trump} =
        Pidro.Game.Engine.apply_action(west_about_to_go_cold(), :west, {:play_card, {4, :hearts}})

      assert last_trump.current_turn == :south
      assert BotBrain.should_make_move?(last_trump, :south)

      {:ok, settled} =
        Pidro.Game.Engine.apply_action(last_trump, :south, {:play_card, {14, :hearts}})

      assert settled.players.west.eliminated?
      assert settled.current_turn == :south
      refute BotBrain.should_make_move?(settled, :south)
      assert BotBrain.should_make_move?(west_about_to_go_cold(), :west)
    end
  end

  defp receive_state_update do
    assert_receive {:state_update, _room_code, payload}, 1_000
    {System.monotonic_time(:millisecond), payload}
  end

  # East won the first trick with the jack; north and east played their last
  # trumps into it. South leads the second, and west's four is its last trump.
  defp west_about_to_go_cold do
    base = Pidro.Core.GameState.new(seed: 1)

    hands = %{
      north: [],
      east: [],
      south: [{14, :hearts}, {10, :hearts}, {5, :hearts}, {2, :hearts}],
      west: [{4, :hearts}, {9, :clubs}]
    }

    first = %Trick{
      number: 1,
      leader: :east,
      plays: [east: {11, :hearts}, south: {7, :hearts}, west: {3, :hearts}, north: {6, :hearts}],
      winner: :east,
      points: 1
    }

    players =
      Map.new(base.players, fn {position, player} ->
        {position,
         %{
           player
           | hand: hands[position],
             eliminated?: position in [:north, :east],
             tricks_won: if(position == :east, do: 1, else: 0)
         }}
      end)

    %{
      base
      | phase: :playing,
        trump_suit: :hearts,
        current_dealer: :east,
        current_turn: :west,
        highest_bid: {:south, 8},
        bidding_team: :north_south,
        bids: [%Bid{position: :south, amount: 8}],
        players: players,
        tricks: [first],
        current_trick: %Trick{number: 2, leader: :south, plays: [south: {12, :hearts}]},
        trick_number: 2,
        hand_points: %{north_south: 0, east_west: 1},
        events: [{:cards_dealt, %{}}]
    }
  end

  describe "abandoned room cleanup" do
    test "removes abandoned room (inactive + no players)" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      # Clear the host's position to make the room empty
      # (host is auto-assigned to :north)
      {:ok, _} = RoomManager.dev_set_position(room.code, :north, nil)

      # Verify room still exists but has no players
      assert {:ok, empty_room} = RoomManager.get_room(room.code)
      assert Positions.count(empty_room) == 0

      # Set activity to > 5 minutes ago
      old_time = DateTime.utc_now() |> DateTime.add(-301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      # Trigger cleanup manually
      send(RoomManager, :cleanup_abandoned_rooms)

      # Allow message processing
      Process.sleep(50)

      # Room should be gone
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "does not remove room with active players even if idle" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      # Set activity to old
      old_time = DateTime.utc_now() |> DateTime.add(-301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      # Trigger cleanup
      send(RoomManager, :cleanup_abandoned_rooms)
      Process.sleep(50)

      # Room should still exist because user1 is active
      assert {:ok, _} = RoomManager.get_room(room.code)
    end

    test "does not remove room with active spectators even if idle" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")
      {:ok, _, _} = RoomManager.join_room(room.code, "user3")
      {:ok, _, _} = RoomManager.join_room(room.code, "user4")
      RoomFixtures.ready_room(room.code)

      {:ok, _} = RoomManager.join_spectator_room(room.code, "spectator1")

      old_time = DateTime.utc_now() |> DateTime.add(-301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      send(RoomManager, :cleanup_abandoned_rooms)
      Process.sleep(50)

      assert {:ok, _} = RoomManager.get_room(room.code)
    end
  end

  describe "dev_set_position/3 - GitHub Issue #6" do
    test "sets a position to a user" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :north, "user2")

      assert updated_room.positions[:north] == "user2"
      assert Positions.has_player?(updated_room, "user2")
    end

    test "clears a seat when user_id is nil" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, room_with_player} = RoomManager.dev_set_position(room.code, :south, "user2")

      assert room_with_player.positions[:south] == "user2"

      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :south, nil)

      assert updated_room.positions[:south] == nil
      refute Positions.has_player?(updated_room, "user2")
    end

    test "four assigned players wait for explicit readiness" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      {:ok, room2} = RoomManager.dev_set_position(room.code, :north, "user1")
      assert room2.status == :waiting

      {:ok, room3} = RoomManager.dev_set_position(room.code, :east, "user2")
      assert room3.status == :waiting

      {:ok, room4} = RoomManager.dev_set_position(room.code, :south, "user3")
      assert room4.status == :waiting

      # Dev seating follows the same readiness contract as ordinary joins.
      {:ok, final_room} = RoomManager.dev_set_position(room.code, :west, "user4")
      assert final_room.status == :waiting
      assert Positions.count(final_room) == 4
      assert RoomFixtures.ready_room(room.code).status == :playing
    end

    test "broadcasts to correct topics on position change" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      # Subscribe to both topics
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user2")

      # Should receive room update
      assert_receive {:room_update, updated_room}, 100
      assert updated_room.positions[:east] == "user2"

      # Should receive lobby event
      assert_receive {:room_updated, _room}, 100
    end

    test "allows changes during :playing status (no restrictions)" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _} = RoomManager.dev_set_position(room.code, :north, "user1")
      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user2")
      {:ok, _} = RoomManager.dev_set_position(room.code, :south, "user3")

      # Change status to playing before 4th player
      :ok = RoomManager.update_room_status(room.code, :playing)

      # Should still allow position changes and preserve :playing status
      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :west, "user4")
      assert updated_room.positions[:west] == "user4"
      assert updated_room.status == :playing
      assert Positions.count(updated_room) == 4
    end

    test "allows changes during :playing status (after auto-start)" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _} = RoomManager.dev_set_position(room.code, :north, "user1")
      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user2")
      {:ok, _} = RoomManager.dev_set_position(room.code, :south, "user3")
      {:ok, _} = RoomManager.dev_set_position(room.code, :west, "user4")

      playing_room = RoomFixtures.ready_room(room.code)
      assert playing_room.status == :playing

      # Should allow changing a seat even during :playing status
      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :north, "user5")
      assert updated_room.positions[:north] == "user5"
    end

    test "allows changes during :finished status" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      :ok = RoomManager.update_room_status(room.code, :finished)

      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :south, "user2")
      assert updated_room.positions[:south] == "user2"
      assert updated_room.status == :finished
    end

    test "returns error for invalid position" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      assert {:error, :invalid_position} =
               RoomManager.dev_set_position(room.code, :invalid, "user2")
    end

    test "returns error for non-existent room" do
      assert {:error, :room_not_found} =
               RoomManager.dev_set_position("ZZZZ", :north, "user1")
    end

    test "replaces player at position when reassigning" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.dev_set_position(room.code, :north, "user2")

      assert room2.positions[:north] == "user2"

      # Replace user2 with user3 at north
      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :north, "user3")

      assert updated_room.positions[:north] == "user3"
      # user2 should no longer be in the room
      refute Positions.has_player?(updated_room, "user2")
      assert Positions.has_player?(updated_room, "user3")
    end

    test "updates player_rooms mapping correctly when replacing" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user2")

      # user2 should be mapped to this room
      {:ok, room_check} = RoomManager.get_room(room.code)
      assert Positions.has_player?(room_check, "user2")

      # Replace user2 with user3
      {:ok, _} = RoomManager.dev_set_position(room.code, :east, "user3")

      # user2 should be able to join another room now (not blocked)
      {:ok, new_room} = RoomManager.create_room("user2", %{})
      assert new_room.host_id == "user2"
    end

    test "moves player from one position to another, clearing old position" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      {:ok, _} = RoomManager.dev_set_position(room.code, :north, "user2")

      # Move user2 from north to south
      {:ok, _} = RoomManager.dev_set_position(room.code, :south, "user2")
      {:ok, updated_room} = RoomManager.get_room(room.code)

      # user2 should now be at south only, old position (north) should be cleared
      assert updated_room.positions[:south] == "user2"
      assert updated_room.positions[:north] == nil

      # Verify user occupies exactly one seat
      seats = [
        updated_room.positions[:north],
        updated_room.positions[:south],
        updated_room.positions[:east],
        updated_room.positions[:west]
      ]

      assert Enum.count(seats, &(&1 == "user2")) == 1
    end

    test "updates last_activity timestamp" do
      {:ok, room} = RoomManager.create_room("user1", %{})
      initial_activity = room.last_activity

      # Wait a tiny bit to ensure timestamp difference
      Process.sleep(10)

      {:ok, updated_room} = RoomManager.dev_set_position(room.code, :north, "user2")

      assert DateTime.compare(updated_room.last_activity, initial_activity) == :gt
    end
  end

  describe "room identity" do
    test "create_room/2 assigns a UUID id and the invite defaults" do
      {:ok, room} = RoomManager.create_room("user1", %{})

      assert {:ok, _uuid} = Ecto.UUID.cast(room.id)
      assert room.locked == false
      assert room.kicked_ids == []
      assert room.invite_live_until == nil
    end

    test "every room gets its own id" do
      {:ok, room1} = RoomManager.create_room("user1", %{})
      {:ok, room2} = RoomManager.create_room("user2", %{})

      assert room1.id != room2.id
    end
  end

  describe "claim_seat/4 room identity" do
    setup do
      original = Application.get_env(:pidro_server, RoomCodes)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pidro_server, RoomCodes, original),
          else: Application.delete_env(:pidro_server, RoomCodes)
      end)

      :ok
    end

    test "seats the caller with the live room id and refuses a stale id for a reused code" do
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ZZZZ" end)
      {:ok, %{code: "ZZZZ", id: stale_id}} = RoomManager.create_room("host-a", %{})
      :ok = RoomManager.leave_room("host-a")
      {:ok, %{code: "ZZZZ", id: live_id}} = RoomManager.create_room("host-b", %{})

      assert stale_id != live_id

      assert {:error, :room_not_found} =
               RoomManager.claim_seat("ZZZZ", stale_id, "guest", display_name: "Guest")

      assert {:ok, room, :east, true} =
               RoomManager.claim_seat("ZZZZ", live_id, "guest", display_name: "Guest")

      assert room.positions[:east] == "guest"
      assert Seat.connected_human?(room.seats[:east])
      assert {:ok, %{positions: %{east: "guest"}}} = RoomManager.get_room("ZZZZ")
    end

    test "returns :room_not_found for an unknown code" do
      assert {:error, :room_not_found} =
               RoomManager.claim_seat("NOPE", Ecto.UUID.generate(), "guest", [])
    end
  end

  describe "claim_seat/4" do
    test "honours the seat hint and falls back on a second claim with the same hint" do
      {room, [_host]} = RoomFixtures.waiting_room_fixture()

      assert {:ok, _room, :south, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :south)

      assert {:ok, updated, :east, false} =
               RoomManager.claim_seat(room.code, room.id, "guest2", hint: :south)

      assert updated.positions == %{north: "host", east: "guest2", south: "guest1", west: nil}
    end

    test "honours a team hint" do
      {room, _ids} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:ok, _room, :west, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :east_west)
    end

    test "resolves :partner to the seat opposite the host after the host has moved" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()
      {:ok, _moved} = RoomManager.move_seat(room.code, host, host, :east)

      assert {:ok, updated, :west, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :partner)

      assert updated.positions[:west] == "guest1"
    end

    test "returns :room_not_found for :partner when the host has no seat" do
      {room, [_host]} = RoomFixtures.waiting_room_fixture()
      {:ok, _room} = RoomManager.dev_set_position(room.code, :north, nil)

      assert {:error, :room_not_found} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :partner)
    end

    test "an explicit taken position returns next_open in N/E/S/W order" do
      {room, [_host]} = RoomFixtures.waiting_room_fixture()
      {:ok, _room, :south} = RoomManager.join_room(room.code, "user2", :south)

      assert {:error, {:seat_taken, [:east, :west]}} =
               RoomManager.claim_seat(room.code, room.id, "guest1", position: :north)

      assert {:error, {:seat_taken, [:east, :west]}} =
               RoomManager.claim_seat(room.code, room.id, "guest1", position: :south)

      assert {:ok, _room, :west, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", position: :west, hint: :north)
    end

    test "a caller already seated at the table gets the current seat and nothing changes" do
      {room, [_host]} = RoomFixtures.waiting_room_fixture()
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      {:ok, seated, :east, true} = RoomManager.claim_seat(room.code, room.id, "guest1", [])
      assert_receive {:invite_redeemed, %{user_id: "guest1"}}, 100

      assert {:ok, again, :east, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", hint: :west)

      assert again.positions == seated.positions
      assert again.seats == seated.seats
      assert again.last_activity == seated.last_activity
      refute_receive {:invite_redeemed, _payload}, 50
    end

    test "a caller connected in another room gets :already_in_room" do
      {room_a, _ids} = RoomFixtures.waiting_room_fixture(host_id: "host-a", seated: 2)
      {room_b, _ids} = RoomFixtures.waiting_room_fixture(host_id: "host-b", prefix: "b")

      assert {:error, :already_in_room} =
               RoomManager.claim_seat(room_b.code, room_b.id, "user2", [])

      assert {:ok, %{positions: %{east: "user2"}}} = RoomManager.get_room(room_a.code)
    end

    test "evicts a caller whose seat elsewhere is held and vacates that seat" do
      {room_a, [_host_a, "user2"]} =
        RoomFixtures.waiting_room_fixture(host_id: "host-a", seated: 2)

      {room_b, _ids} = RoomFixtures.waiting_room_fixture(host_id: "host-b", prefix: "b")
      :ok = RoomManager.handle_player_disconnect(room_a.code, "user2")

      assert {:ok, seated, :east, true} =
               RoomManager.claim_seat(room_b.code, room_b.id, "user2", [])

      assert seated.positions[:east] == "user2"

      {:ok, room_a_after} = RoomManager.get_room(room_a.code)
      assert room_a_after.positions[:east] == nil
      assert Seat.vacant?(room_a_after.seats[:east])

      # The caller is now tracked in room B: leaving removes them from B.
      :ok = RoomManager.leave_room("user2")
      assert {:ok, %{positions: %{east: nil}}} = RoomManager.get_room(room_b.code)
    end

    test "the fourth claim waits for readiness before starting the game" do
      {room, _ids} = RoomFixtures.waiting_room_fixture(seated: 3)

      assert {:ok, %{status: :waiting}, :west, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", [])

      RoomFixtures.ready_room(room.code)

      wait_until(fn ->
        match?({:ok, %{status: :playing}}, RoomManager.get_room(room.code))
      end)
    end

    test "broadcasts invite_redeemed with distinct account names on game:<code>" do
      {room, _ids} = RoomFixtures.waiting_room_fixture()
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      assert {:ok, _room, :east, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1",
                 username: "ada_123",
                 display_name: "Ada"
               )

      assert_receive {:invite_redeemed,
                      %{
                        position: :east,
                        user_id: "guest1",
                        username: "ada_123",
                        display_name: "Ada"
                      }},
                     100

      assert_receive {:room_update, %{positions: %{east: "guest1"}}}, 100
      assert_receive {:room_updated, %{positions: %{east: "guest1"}}}, 100
    end

    test "touches last_activity" do
      {room, _ids} = RoomFixtures.waiting_room_fixture()
      old_time = DateTime.add(DateTime.utc_now(), -301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      assert {:ok, updated, _position, true} =
               RoomManager.claim_seat(room.code, room.id, "guest1", [])

      assert DateTime.compare(updated.last_activity, old_time) == :gt
    end

    test "refuses a room that is not waiting" do
      room_code = create_playing_room()
      {:ok, room} = RoomManager.get_room(room_code)

      assert {:error, :room_not_available} =
               RoomManager.claim_seat(room_code, room.id, "guest1", [])
    end
  end

  describe "note_invite/2" do
    test "stores the given value, including nil, and the room stays lobby-visible" do
      {room, _ids} = RoomFixtures.waiting_room_fixture()
      until = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert :ok = RoomManager.note_invite(room.code, until)
      assert {:ok, %{invite_live_until: ^until} = live} = RoomManager.get_room(room.code)
      assert RoomManager.visible_in_lobby?(live)
      assert Enum.any?(RoomManager.list_lobby("someone").open_tables, &(&1.code == room.code))
      assert Enum.any?(RoomManager.list_rooms(:waiting), &(&1.code == room.code))

      assert :ok = RoomManager.note_invite(room.code, nil)
      assert {:ok, %{invite_live_until: nil}} = RoomManager.get_room(room.code)
    end

    test "touches last_activity" do
      {room, _ids} = RoomFixtures.waiting_room_fixture()
      old_time = DateTime.add(DateTime.utc_now(), -301, :second)
      :ok = RoomManager.set_last_activity_for_test(room.code, old_time)

      :ok = RoomManager.note_invite(room.code, DateTime.utc_now())

      {:ok, updated} = RoomManager.get_room(room.code)
      assert DateTime.compare(updated.last_activity, old_time) == :gt
    end

    test "returns :room_not_found for an unknown code" do
      assert {:error, :room_not_found} = RoomManager.note_invite("NOPE", nil)
    end
  end

  describe "set_locked/3" do
    test "the host locks and unlocks the table" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()

      assert {:ok, %{locked: true}} = RoomManager.set_locked(room.code, host, true)
      assert {:ok, %{locked: true}} = RoomManager.get_room(room.code)
      assert {:error, :table_locked} = RoomManager.join_room(room.code, "user2")

      assert {:error, :table_locked} =
               RoomManager.claim_seat(room.code, room.id, "guest1", [])

      assert {:ok, %{locked: false}} = RoomManager.set_locked(room.code, host, false)
      assert {:ok, _room, :east} = RoomManager.join_room(room.code, "user2")
    end

    test "a locked room still accepts a reclaim of a disconnected seat" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      {:ok, _locked} = RoomManager.set_locked(room.code, host, true)

      :sys.replace_state(RoomManager, fn %RoomManager.State{} = manager_state ->
        current = Map.fetch!(manager_state.rooms, room.code)
        {:ok, held} = Seat.disconnect(current.seats[:east])
        updated = %{current | seats: Map.put(current.seats, :east, held)}
        %{manager_state | rooms: Map.put(manager_state.rooms, room.code, updated)}
      end)

      assert {:ok, reclaimed} = RoomManager.handle_player_reconnect(room.code, "user2")
      assert Seat.connected_human?(reclaimed.seats[:east])
      assert reclaimed.locked
    end

    test "a non-host gets :not_owner" do
      {room, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:error, :not_owner} = RoomManager.set_locked(room.code, "user2", true)
      assert {:ok, %{locked: false}} = RoomManager.get_room(room.code)
    end

    test "refuses a room that is not waiting" do
      room_code = create_playing_room()

      assert {:error, :room_not_waiting} = RoomManager.set_locked(room_code, "user1", true)
    end

    test "broadcasts the room and lobby updates" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      {:ok, _room} = RoomManager.set_locked(room.code, host, true)

      assert_receive {:room_update, %{locked: true}}, 100
      assert_receive {:room_updated, %{locked: true}}, 100
    end
  end

  describe "kick_player/3" do
    test "vacates the seat, records the id, notifies the channel and clears the mapping" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      :ok = RoomManager.register_game_channel(room.code, "user2", self())
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")

      assert {:ok, kicked} = RoomManager.kick_player(room.code, host, :east)

      assert kicked.positions[:east] == nil
      assert Seat.vacant?(kicked.seats[:east])
      assert kicked.kicked_ids == ["user2"]
      assert kicked.status == :waiting
      assert_receive {:force_disconnect, :kicked}, 100
      assert_receive {:kicked, %{position: :east, user_id: "user2"}}, 100
      assert_receive {:room_update, %{positions: %{east: nil}}}, 100

      assert {:error, :not_in_room} = RoomManager.leave_room("user2")
      assert {:ok, _room} = RoomManager.create_room("user2", %{})
    end

    test "a kicked id is refused on join, claim and a later substitute join" do
      PidroServer.DataCase.setup_sandbox(%{async: false})
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      {:ok, _room} = RoomManager.kick_player(room.code, host, :east)

      assert {:error, :kicked} = RoomManager.join_room(room.code, "user2")
      assert {:error, :kicked} = RoomManager.claim_seat(room.code, room.id, "user2", [])

      {:ok, _room, _pos} = RoomManager.join_room(room.code, "user3")
      {:ok, _room, _pos} = RoomManager.join_room(room.code, "user4")
      {:ok, _room, user5_position} = RoomManager.join_room(room.code, "user5")
      RoomFixtures.ready_room(room.code)

      wait_until(fn ->
        match?({:ok, %{status: :playing}}, RoomManager.get_room(room.code))
      end)

      # Only an intentional leave releases the seat for substitutes.
      :ok = RoomManager.handle_player_disconnect(room.code, "user5")
      PidroServer.RoomManagerCase.expire_phase(room.code, user5_position, :phase2_start)
      :ok = RoomManager.leave_room("user5")

      wait_until(fn ->
        match?(
          {:ok, %{seats: %{^user5_position => %{status: :bot_substitute}}}},
          RoomManager.get_room(room.code)
        )
      end)

      {:ok, _room} = RoomManager.open_seat(room.code, user5_position, host)

      assert {:error, :kicked} = RoomManager.join_as_substitute(room.code, "user2")
      assert {:ok, _room, ^user5_position} = RoomManager.join_as_substitute(room.code, "user6")
    end

    test "records a user id only once if dev tooling seats and kicks it again" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:ok, _kicked} = RoomManager.kick_player(room.code, host, :east)
      assert {:ok, _reseated} = RoomManager.dev_set_position(room.code, :east, "user2")
      assert {:ok, kicked_again} = RoomManager.kick_player(room.code, host, :east)

      assert kicked_again.kicked_ids == ["user2"]
    end

    test "the host's own seat and vacant seats are not kickable" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:error, :seat_not_kickable} = RoomManager.kick_player(room.code, host, :north)
      assert {:error, :seat_not_kickable} = RoomManager.kick_player(room.code, host, :west)
      assert {:ok, %{positions: %{north: ^host, east: "user2"}}} = RoomManager.get_room(room.code)
    end

    test "a non-host gets :not_owner" do
      {room, [_host, "user2", "user3"]} = RoomFixtures.waiting_room_fixture(seated: 3)

      assert {:error, :not_owner} = RoomManager.kick_player(room.code, "user2", :south)
      assert {:ok, %{positions: %{south: "user3"}}} = RoomManager.get_room(room.code)
    end

    test "refuses a room that is not waiting" do
      room_code = create_playing_room()

      assert {:error, :room_not_waiting} = RoomManager.kick_player(room_code, "user1", :east)
    end
  end

  describe "move_seat/4" do
    test "the host moves another player to a vacant seat and broadcasts seat_moved" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "room:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      assert {:ok, moved} = RoomManager.move_seat(room.code, host, "user2", :west)

      assert moved.positions == %{north: host, east: nil, south: nil, west: "user2"}
      assert Seat.vacant?(moved.seats[:east])
      assert %Seat{position: :west, user_id: "user2", is_owner: false} = moved.seats[:west]
      assert Seat.connected_human?(moved.seats[:west])
      assert_receive {:seat_moved, %{user_id: "user2", from: :east, to: :west}}, 100
      assert_receive {:room_update, %{positions: %{west: "user2"}}}, 100
      assert_receive {:room_updated, %{positions: %{west: "user2"}}}, 100
    end

    test "keeps is_owner when the host moves themselves" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()

      assert {:ok, moved} = RoomManager.move_seat(room.code, host, host, :south)

      assert moved.host_id == host
      assert moved.positions == %{north: nil, east: nil, south: host, west: nil}
      assert Seat.owner?(moved.seats[:south])
      assert Seat.vacant?(moved.seats[:north])
      refute Seat.owner?(moved.seats[:north])
    end

    test "a non-host moving someone else gets :not_owner" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:error, :not_owner} = RoomManager.move_seat(room.code, "user2", host, :west)
      assert {:ok, %{positions: %{north: ^host}}} = RoomManager.get_room(room.code)
    end

    test "a non-host moves themselves" do
      {room, [_host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:ok, moved} = RoomManager.move_seat(room.code, "user2", "user2", :south)
      assert moved.positions[:south] == "user2"
      assert moved.positions[:east] == nil
    end

    test "moving onto a taken seat fails with :seat_taken" do
      {room, [host, "user2"]} = RoomFixtures.waiting_room_fixture(seated: 2)

      assert {:error, :seat_taken} = RoomManager.move_seat(room.code, host, "user2", :north)
      assert {:error, :seat_taken} = RoomManager.move_seat(room.code, host, "user2", :east)
    end

    test "moving onto a held seat fails with :seat_taken" do
      {room, [host, "user2", "user3"]} = RoomFixtures.waiting_room_fixture(seated: 3)

      :sys.replace_state(RoomManager, fn %RoomManager.State{} = manager_state ->
        current = Map.fetch!(manager_state.rooms, room.code)
        {:ok, held} = Seat.disconnect(current.seats[:south])
        updated = %{current | seats: Map.put(current.seats, :south, held)}
        %{manager_state | rooms: Map.put(manager_state.rooms, room.code, updated)}
      end)

      assert {:error, :seat_taken} = RoomManager.move_seat(room.code, host, "user2", :south)
      assert {:ok, %{positions: %{south: "user3"}}} = RoomManager.get_room(room.code)
    end

    test "an unseated target returns :player_not_in_room" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()

      assert {:error, :player_not_in_room} =
               RoomManager.move_seat(room.code, host, "stranger", :west)
    end

    test "rejects an invalid position" do
      {room, [host]} = RoomFixtures.waiting_room_fixture()

      assert {:error, :invalid_position} = RoomManager.move_seat(room.code, host, host, :middle)
    end

    test "refuses a room that is not waiting" do
      room_code = create_playing_room()

      assert {:error, :room_not_waiting} =
               RoomManager.move_seat(room_code, "user1", "user1", :west)
    end
  end

  defp create_playing_room(attrs \\ %{}) do
    {:ok, room} = RoomManager.create_room("user1", attrs)
    room_code = room.code

    {:ok, _, _} = RoomManager.join_room(room_code, "user2")
    {:ok, _, _} = RoomManager.join_room(room_code, "user3")
    {:ok, _, _} = RoomManager.join_room(room_code, "user4")

    RoomFixtures.ready_room(room_code)

    _room =
      wait_until(fn ->
        case RoomManager.get_room(room_code) do
          {:ok, %{status: :playing} = room} -> room
          _ -> nil
        end
      end)

    room_code
  end

  defp advance_room_to_bidding(room_code) do
    {:ok, state} = GameAdapter.get_state(room_code)

    if state.phase == :dealer_selection do
      {:ok, _state} = GameAdapter.apply_action(room_code, :north, :select_dealer)
    end

    wait_until(fn ->
      case GameAdapter.get_state(room_code) do
        {:ok, %{phase: :bidding} = state} -> state
        _ -> nil
      end
    end)
  end

  defp wait_for_turn_timer(room_code) do
    wait_until(fn ->
      case RoomManager.get_turn_timer(room_code) do
        {:ok, nil} -> nil
        {:ok, turn_timer} -> turn_timer
        _ -> nil
      end
    end)
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(_fun, 0) do
    flunk("timed out waiting for condition")
  end

  defp wait_until(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      false ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end

  # Returns a zero-arity room code generator that yields `codes` in order and
  # then repeats the last one forever. Runs inside the RoomManager process.
  defp sequence_generator(codes) do
    index = :counters.new(1, [])
    codes = List.to_tuple(codes)

    fn ->
      position = :counters.get(index, 1)
      :counters.add(index, 1, 1)
      elem(codes, min(position, tuple_size(codes) - 1))
    end
  end
end
