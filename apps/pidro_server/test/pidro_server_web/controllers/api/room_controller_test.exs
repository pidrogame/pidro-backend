defmodule PidroServerWeb.API.RoomControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  alias PidroServer.Accounts.{Token, UserIdentities}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.Bots.{BotManager, BotSupervisor}
  alias PidroServer.Games.{RoomCodes, RoomManager}
  alias PidroServer.Games.Room.Config

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  test "a seat in the room snapshot carries a photo-less player's face (PID-395)", %{conn: conn} do
    host = AccountsFixtures.user_fixture()
    {:ok, host} = PidroServer.Accounts.Avatars.put_face(host, "b")
    plain = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Faces"})
    {:ok, _, _} = RoomManager.join_room(room.code, plain.id)

    seats =
      conn
      |> put_req_header("authorization", "Bearer #{Token.generate(host)}")
      |> get(~p"/api/v1/rooms/#{room.code}")
      |> json_response(200)
      |> get_in(["data", "room", "seats"])
      |> Map.values()
      |> Map.new(&{&1["user_id"], &1["avatar_url"]})

    assert seats[host.id] == PidroServerWeb.Endpoint.url() <> "/images/faces/b.png"
    assert Map.fetch!(seats, plain.id) == nil

    assert {:ok, %{seats: snapshot}} = RoomManager.get_seat_lifecycle(room.code)

    assert Enum.find(Map.values(snapshot), &(&1.player_id == host.id)).avatar_url ==
             PidroServerWeb.Endpoint.url() <> "/images/faces/b.png"
  end

  test "game state exposes trick signals and the retained hand result over HTTP", %{conn: conn} do
    host = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{name: "Trick signals"})

    for _ <- 1..3 do
      user = AccountsFixtures.user_fixture()
      {:ok, _, _} = RoomManager.join_room(room.code, user.id)
    end

    PidroServer.RoomFixtures.ready_room(room.code)

    scored =
      1
      |> Pidro.Test.DeterministicGame.opening()
      |> Pidro.Test.DeterministicGame.play_until(&(&1.hand_number == 2))

    trick = %Pidro.Core.Types.Trick{
      number: 1,
      leader: :north,
      plays: [{:north, {5, :diamonds}}, {:east, {2, :hearts}}, {:south, {10, :hearts}}]
    }

    state = %{
      scored
      | phase: :playing,
        trump_suit: :hearts,
        current_trick: trick,
        trick_number: 1
    }

    {:ok, pid} = PidroServer.Games.GameRegistry.lookup(room.code)
    :ok = GenServer.call(pid, {:set_state, state})

    response =
      as_user(conn, host) |> get(~p"/api/v1/rooms/#{room.code}/state") |> json_response(200)

    payload = response["data"]["state"]

    serialized_last_hand =
      PidroServerWeb.Serializers.GameStateSerializer.serialize(scored).last_hand

    assert payload["last_hand"] == serialized_last_hand |> Jason.encode!() |> Jason.decode!()
    assert [_ | _] = payload["last_hand"]["tricks"]
    assert [_ | _] = payload["last_hand"]["bids"]
    assert [_ | _] = payload["last_hand"]["point_cards"]
    assert [%{"hand_number" => 1}] = payload["hand_history"]
    assert payload["scores"] == payload["cumulative_scores"]
    assert payload["current_trick"] == payload["current_trick_details"]["plays"]

    assert payload["current_trick_details"]["winning"] == %{
             "position" => "south",
             "card" => %{"rank" => 10, "suit" => "hearts"}
           }

    assert payload["current_trick_details"]["points"] == 6

    assert payload["current_trick_details"]["two_of_trump"] == %{
             "position" => "east",
             "points" => 1
           }

    OpenApiSpex.TestAssertions.assert_schema(
      response,
      "GameStateResponse",
      PidroServerWeb.ApiSpec.spec()
    )

    :ok = GenServer.call(pid, {:set_state, %{state | current_trick: nil}})

    response =
      as_user(conn, host) |> get(~p"/api/v1/rooms/#{room.code}/state") |> json_response(200)

    assert response["data"]["state"]["current_trick_details"] == nil

    OpenApiSpex.TestAssertions.assert_schema(
      response,
      "GameStateResponse",
      PidroServerWeb.ApiSpec.spec()
    )
  end

  test "held seats are visible everywhere, invite their user, and exclude strangers", %{
    conn: conn
  } do
    host = AccountsFixtures.user_fixture(%{display_name: "Ada"})
    friend = AccountsFixtures.user_fixture(%{display_name: "Nora"})
    stranger = AccountsFixtures.user_fixture()

    created =
      as_user(conn, host)
      |> post(~p"/api/v1/rooms", %{seats: %{seat_3: %{type: "held", user_id: friend.id}}})
      |> json_response(201)

    room = created["data"]["room"]
    code = room["code"]
    held_for = %{"user_id" => friend.id, "display_name" => "Nora", "avatar_url" => nil}
    assert room["available_positions"] == ["east", "west"]
    assert room["seats"]["south"]["status"] == "free"
    assert room["seats"]["south"]["held_for"] == held_for
    assert room["seats"]["south"]["min_games"] == 0

    detail = get(conn, ~p"/api/v1/rooms/#{code}") |> json_response(200)
    assert detail["data"]["room"]["seats"]["south"]["held_for"] == held_for
    lobby = as_user(conn, stranger) |> get(~p"/api/v1/lobby") |> json_response(200)
    assert hd(lobby["data"]["open_tables"])["seats"]["south"]["held_for"] == held_for

    me = as_user(conn, friend) |> get(~p"/api/v1/auth/me") |> json_response(200)

    {:ok, live_room} = RoomManager.get_room(code)

    assert me["data"]["seat_invitations"] == [
             %{
               "code" => code,
               "position" => "south",
               "host_id" => host.id,
               "host" => %{
                 "user_id" => host.id,
                 "display_name" => host.display_name,
                 "avatar_url" => nil
               },
               "rule_set" => "finnish",
               "held_since" => DateTime.to_iso8601(live_room.created_at),
               "join_as" => "partner"
             }
           ]

    OpenApiSpex.TestAssertions.assert_schema(me, "User Response", PidroServerWeb.ApiSpec.spec())

    legacy =
      put_in(me, ["data", "seat_invitations"], [
        %{"code" => code, "position" => "south", "host_id" => host.id}
      ])

    OpenApiSpex.TestAssertions.assert_schema(
      legacy,
      "User Response",
      PidroServerWeb.ApiSpec.spec()
    )

    me = as_user(conn, stranger) |> get(~p"/api/v1/auth/me") |> json_response(200)
    assert me["data"]["seat_invitations"] == []

    refused =
      as_user(conn, stranger)
      |> post(~p"/api/v1/rooms/#{code}/join", %{position: "south"})
      |> json_response(422)

    assert hd(refused["errors"])["code"] == "SEAT_TAKEN"
    assert {:error, :seat_taken} = RoomManager.move_seat(code, host.id, host.id, :south)
    assert {:error, :seat_taken} = RoomManager.join_bot(code, "bot_test", self(), :south)
    assert {:error, :not_enough_seats} = BotManager.start_bots(code, 3, :basic)

    seated =
      as_user(conn, friend) |> post(~p"/api/v1/rooms/#{code}/join", %{}) |> json_response(200)

    assert seated["data"]["assigned_position"] == "south"
    refute Map.has_key?(seated["data"]["room"]["seats"]["south"], "held_for")
    assert RoomManager.seat_invitations(friend.id) == []
    {:ok, after_join} = RoomManager.get_room(code)
    assert after_join.config.seat_holds == %{}
  end

  test "/auth/me says which held seat is the host's partner", %{conn: conn} do
    host = AccountsFixtures.user_fixture()
    [east, south, west] = for _ <- 1..3, do: AccountsFixtures.user_fixture()

    holds = %{
      seat_2: %{type: "held", user_id: east.id},
      seat_3: %{type: "held", user_id: south.id},
      seat_4: %{type: "held", user_id: west.id}
    }

    as_user(conn, host) |> post(~p"/api/v1/rooms", %{seats: holds}) |> json_response(201)

    for {friend, position, join_as} <- [
          {east, "east", "opponent"},
          {south, "south", "partner"},
          {west, "west", "opponent"}
        ] do
      me = as_user(conn, friend) |> get(~p"/api/v1/auth/me") |> json_response(200)
      assert [%{"position" => ^position, "join_as" => ^join_as}] = me["data"]["seat_invitations"]
    end
  end

  test "only the waiting host can hold and release; holds bypass experience and block start", %{
    conn: conn
  } do
    host = AccountsFixtures.user_fixture()
    friend = AccountsFixtures.user_fixture()
    stranger = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{seat_requirements: %{south: 1000}})
    path = ~p"/api/v1/rooms/#{room.code}/seats/south/hold"

    assert as_user(conn, stranger) |> put(path, %{user_id: friend.id}) |> json_response(403)
    assert as_user(conn, host) |> put(path, %{}) |> json_response(422)
    assert as_user(conn, host) |> put(path, %{user_id: "bad"}) |> json_response(422)

    assert as_user(conn, host)
           |> put(path, %{user_id: Ecto.UUID.generate()})
           |> json_response(422)

    assert as_user(conn, host)
           |> put(~p"/api/v1/rooms/#{room.code}/seats/north/hold", %{user_id: friend.id})
           |> json_response(422)

    held = as_user(conn, host) |> put(path, %{user_id: friend.id}) |> json_response(200)
    assert held["data"]["room"]["seats"]["south"]["min_games"] == 0
    assert as_user(conn, stranger) |> delete(path) |> json_response(403)
    {:ok, _, :east} = RoomManager.join_room(room.code, stranger.id, :east)
    fourth = AccountsFixtures.user_fixture()
    {:ok, _room, :west} = RoomManager.join_room(room.code, fourth.id, :west)
    :ok = RoomManager.register_game_channel(room.code, host.id, self())
    {:ok, snapshot} = RoomManager.readiness(room.code)

    assert {:error, :table_not_full, blocked} =
             RoomManager.confirm_ready(room.code, room.id, host.id, self(), snapshot.ready_epoch)

    assert blocked.seats.south.held_for.user_id == friend.id

    assert PidroServerWeb.API.RoomJSON.readiness(blocked).seats.south.held_for.display_name ==
             friend.username

    assert {:error, :not_found} = PidroServer.Games.GameSupervisor.get_game(room.code)

    released = as_user(conn, host) |> delete(path) |> json_response(200)
    assert released["data"]["room"]["available_positions"] == ["south"]
    assert released["data"]["room"]["seats"]["south"]["min_games"] == 1000
    assert RoomManager.seat_invitations(friend.id) == []
    assert as_user(conn, host) |> put(path, %{user_id: friend.id}) |> json_response(200)
    assert {:ok, _, :south} = RoomManager.join_room(room.code, friend.id, :south)
    playing = PidroServer.RoomFixtures.ready_room(room.code)
    assert playing.status == :playing
    assert as_user(conn, host) |> put(path, %{user_id: friend.id}) |> json_response(409)
    assert as_user(conn, host) |> delete(path) |> json_response(409)
  end

  test "only the invited player can decline a held seat, once", %{conn: conn} do
    host = AccountsFixtures.user_fixture()
    friend = AccountsFixtures.user_fixture()

    {:ok, room} =
      RoomManager.create_room(host.id, %{
        seat_holds: %{south: friend.id},
        seat_requirements: %{south: 100}
      })

    path = ~p"/api/v1/rooms/#{room.code}/seats/south/decline"

    for user <- [host, AccountsFixtures.user_fixture()] do
      assert %{"errors" => [%{"code" => "INVITATION_GONE"}], "error_code" => "invitation_gone"} =
               as_user(conn, user) |> post(path) |> json_response(404)
    end

    assert as_user(conn, friend)
           |> post(~p"/api/v1/rooms/#{room.code}/seats/up/decline")
           |> json_response(422)

    declined = as_user(conn, friend) |> post(path) |> json_response(200)
    assert declined["data"]["room"]["available_positions"] == ["east", "south", "west"]
    assert declined["data"]["room"]["seats"]["south"]["min_games"] == 100
    assert RoomManager.seat_invitations(friend.id) == []

    assert %{"errors" => [%{"code" => "INVITATION_GONE"}]} =
             as_user(conn, friend) |> post(path) |> json_response(404)

    assert as_user(conn, friend)
           |> post(~p"/api/v1/rooms/ZZZZ/seats/south/decline")
           |> json_response(404)
  end

  test "ending a room removes pending invitations and invalid held create bodies fail", %{
    conn: conn
  } do
    host = AccountsFixtures.user_fixture()
    friend = AccountsFixtures.user_fixture()

    for entry <- [
          %{type: "held"},
          %{type: "held", user_id: "bad"},
          %{type: "held", user_id: Ecto.UUID.generate()},
          %{type: "held", user_id: friend.id, min_games: 100}
        ] do
      assert as_user(conn, host)
             |> post(~p"/api/v1/rooms", %{seats: %{seat_3: entry}})
             |> json_response(422)
    end

    {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{south: friend.id}})
    assert [_] = RoomManager.seat_invitations(friend.id)
    :ok = RoomManager.close_room(room.code)
    assert RoomManager.seat_invitations(friend.id) == []
  end

  test "playing room payloads share progress and preserve the departed player's name", %{
    conn: conn
  } do
    [host, departed | others] =
      Enum.map(1..4, &AccountsFixtures.user_fixture(%{display_name: "Player #{&1}"}))

    {:ok, room} = RoomManager.create_room(host.id)

    {:ok, invite} =
      PidroServer.Invites.create_invite(%{
        room_id: room.id,
        room_code: room.code,
        host_user_id: host.id
      })

    waiting = as_user(conn, host) |> get(~p"/api/v1/rooms/#{room.code}") |> json_response(200)
    refute Map.has_key?(waiting["data"]["room"], "game")
    {:ok, readiness} = RoomManager.readiness(room.code)
    refute Map.has_key?(readiness, :game)

    for user <- [departed | others], do: RoomManager.join_room(room.code, user.id)
    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, snapshot} = PidroServer.Games.GameAdapter.get_snapshot(room.code)
    snapshot = Map.put(snapshot, :transition_delay_ms, 0)

    game = %{
      snapshot.state
      | hand_number: 4,
        cumulative_scores: %{north_south: 34, east_west: 21}
    }

    send(
      RoomManager,
      {:state_update, room.code,
       %{snapshot | state: game, state_revision: snapshot.state_revision + 1}}
    )

    {:ok, _} = RoomManager.get_room(room.code)

    expected = %{"hand" => 4, "scores" => %{"north_south" => 34, "east_west" => 21}}
    detail = as_user(conn, host) |> get(~p"/api/v1/rooms/#{room.code}") |> json_response(200)
    assert detail["data"]["room"]["game"] == expected
    lobby = as_user(conn, departed) |> get(~p"/api/v1/lobby") |> json_response(200)

    assert Enum.find(lobby["data"]["spectatable"], &(&1["code"] == room.code))["game"] ==
             expected

    {:ok, readiness} = RoomManager.readiness(room.code)
    assert Jason.decode!(Jason.encode!(readiness.game)) == expected
    preview = get(conn, ~p"/api/v1/invites/#{invite.code}") |> json_response(200)
    assert preview["data"]["invite"]["game"] == expected

    :ok = RoomManager.handle_player_disconnect(room.code, departed.id)
    {:ok, _} = PidroServer.RoomManagerCase.expire_phase(room.code, :east, :phase2_start)
    :ok = RoomManager.leave_room(departed.id)
    {:ok, gone} = RoomManager.get_room(room.code)
    {:ok, _} = RoomManager.keep_bot(room.code, :east, host.id, gone.seats.east.decision_id)
    {:ok, opened} = RoomManager.open_seat(room.code, :east, host.id)
    assert PidroServerWeb.API.RoomJSON.room(opened).seats.east.vacated_by == "Player 2"
    preview = get(conn, ~p"/api/v1/invites/#{invite.code}") |> json_response(200)

    assert Enum.find(preview["data"]["invite"]["seats"], &(&1["position"] == "east"))[
             "vacated_by"
           ] == "Player 2"

    send(RoomManager, {:game_over, room.code, :north_south, game.cumulative_scores})
    {:ok, finished} = RoomManager.get_room(room.code)
    refute Map.has_key?(PidroServerWeb.API.RoomJSON.room(finished), :game)
  end

  test "a failed profile lookup refuses admission without losing rooms", %{conn: conn} do
    host = AccountsFixtures.user_fixture()
    player = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{seat_requirements: %{south: 100}})
    manager = Process.whereis(RoomManager)
    # Transactional DDL is undone by the Repo sandbox.
    PidroServer.Repo.query!("ALTER TABLE player_profiles RENAME TO unavailable_player_profiles")

    response =
      as_user(conn, player)
      |> post(~p"/api/v1/rooms/#{room.code}/join", %{position: "south"})
      |> json_response(503)

    assert %{"errors" => [%{"code" => "PROFILE_UNAVAILABLE"}]} = response
    assert Process.whereis(RoomManager) == manager
    assert {:ok, unchanged} = RoomManager.get_room(room.code)
    assert unchanged.positions == room.positions
  end

  test "seat requirements use the combined record and survive reclaim", %{conn: conn} do
    host = AccountsFixtures.user_fixture()
    player = AccountsFixtures.user_fixture()
    {:ok, profile} = PidroServer.Profiles.get_or_create_profile(player.id)
    profile |> Ecto.Changeset.change(games_played: 40) |> PidroServer.Repo.update!()

    created =
      as_user(conn, host)
      |> post(~p"/api/v1/rooms", %{
        "seats" => %{"seat_3" => %{"type" => "open", "min_games" => 100}}
      })
      |> json_response(201)

    code = created["data"]["code"]
    assert created["data"]["room"]["seats"]["south"]["min_games"] == 100
    assert created["data"]["room"]["seats"]["north"]["min_games"] == 0

    assert as_user(conn, player)
           |> post(~p"/api/v1/rooms/#{code}/join", %{position: "south"})
           |> json_response(403) ==
             %{
               "error" => "SEAT_REQUIRES_GAMES",
               "min_games" => 100,
               "games_played" => 40,
               "error_code" => "seat_requires_games",
               "error_params" => %{"min_games" => 100, "games_played" => 40}
             }

    {:ok, _} = PidroServer.Profiles.import_legacy_progression(player, %{legacy_played_games: 110})
    assert PidroServer.Profiles.public_profile(player.id).record.games == 150

    joined =
      as_user(conn, player)
      |> post(~p"/api/v1/rooms/#{code}/join", %{position: "south"})
      |> json_response(200)

    assert joined["data"]["assigned_position"] == "south"
    assert joined["data"]["room"]["seats"]["south"]["min_games"] == 0

    {:ok, profile} = PidroServer.Profiles.get_or_create_profile(player.id)

    profile
    |> Ecto.Changeset.change(games_played: 0, heritage_flags: %{})
    |> PidroServer.Repo.update!()

    :ok = RoomManager.handle_player_disconnect(code, player.id)
    assert {:ok, reclaimed} = RoomManager.handle_player_reconnect(code, player.id)
    assert reclaimed.positions.south == player.id
    {:ok, readiness} = RoomManager.readiness(code)
    assert readiness.seats.south.min_games == 0
    assert reclaimed.config.seat_requirements == %{south: 100}
  end

  test "moving into a restricted chair cannot bypass admission", %{conn: conn} do
    host = AccountsFixtures.user_fixture()
    player = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{seat_requirements: %{south: 100}})
    {:ok, _, :east} = RoomManager.join_room(room.code, player.id)

    assert {:error, {:seat_requires_games, 100, 0}} =
             RoomManager.move_seat(room.code, player.id, player.id, :south)

    assert as_user(conn, host)
           |> get(~p"/api/v1/rooms/#{room.code}")
           |> json_response(200)
           |> get_in(["data", "room", "seats", "south", "min_games"]) == 100

    assert {:ok, _, :west} = RoomManager.join_bot(room.code, "bot_test", self(), :west)
    assert {:ok, moved} = RoomManager.move_seat(room.code, host.id, "bot_test", :south)
    assert moved.seats.south.occupant_type == :bot
    assert moved.config.seat_requirements == %{south: 100}
  end

  describe "PID-252 password seats" do
    test "only the host sees the password; a joiner needs it and a reclaim does not", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      player = AccountsFixtures.user_fixture()
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      {created, log} =
        ExUnit.CaptureLog.with_log(fn ->
          as_user(conn, host)
          |> post(~p"/api/v1/rooms", %{
            "seats" => %{"seat_3" => %{"type" => "open", "min_games" => 0, "password" => true}}
          })
          |> json_response(201)
        end)

      code = created["data"]["code"]
      password = created["data"]["room"]["seat_password"]
      assert password =~ ~r/\A\d{4}\z/
      assert created["data"]["room"]["seats"]["south"]["password"] == true
      assert created["data"]["room"]["seats"]["east"]["password"] == false

      {host_room, read_log} =
        ExUnit.CaptureLog.with_log(fn ->
          as_user(conn, host) |> get(~p"/api/v1/rooms/#{code}") |> json_response(200)
        end)

      assert host_room["data"]["room"]["seat_password"] == password

      revoked = Token.generate(host)
      {:ok, host} = PidroServer.Accounts.Auth.bump_token_version(host)

      expired =
        Phoenix.Token.sign(
          PidroServerWeb.Endpoint,
          "pidro_auth_salt",
          %{
            id: host.id,
            v: host.token_version
          },
          signed_at: System.system_time(:second) - 31 * 86_400
        )

      for public_conn <- [
            as_user(conn, player),
            conn,
            put_req_header(conn, "authorization", "Bearer garbage"),
            put_req_header(conn, "authorization", "Bearer #{expired}"),
            put_req_header(conn, "authorization", "Bearer #{revoked}"),
            put_req_header(conn, "authorization", "Basic malformed")
          ] do
        public = public_conn |> get(~p"/api/v1/rooms/#{code}") |> json_response(200)
        refute Map.has_key?(public["data"]["room"], "seat_password")
        assert public["data"]["room"]["seats"]["south"]["password"] == true
      end

      assert read_log =~ "GET /api/v1/rooms"
      refute read_log =~ ~s("#{password}")
      refute read_log =~ "seat_password"

      lobby = as_user(conn, player) |> get(~p"/api/v1/lobby") |> json_response(200)
      listed = Enum.find(lobby["data"]["open_tables"], &(&1["code"] == code))
      assert listed["seats"]["south"]["password"] == true
      refute Map.has_key?(listed, "seat_password")

      {_, join_log} =
        ExUnit.CaptureLog.with_log(fn ->
          for body <- [%{position: "south"}, %{position: "south", password: "0000"}] do
            assert as_user(conn, player)
                   |> post(~p"/api/v1/rooms/#{code}/join", body)
                   |> json_response(403) == %{
                     "errors" => [
                       %{
                         "code" => "SEAT_REQUIRES_PASSWORD",
                         "title" => "Seat requires password",
                         "detail" => "This seat needs the table's password"
                       }
                     ],
                     "error_code" => "seat_requires_password",
                     "error_params" => %{}
                   }
          end

          joined =
            as_user(conn, player)
            |> post(~p"/api/v1/rooms/#{code}/join", %{position: "south", password: password})
            |> json_response(200)

          assert joined["data"]["assigned_position"] == "south"
          refute Map.has_key?(joined["data"]["room"], "seat_password")
          assert joined["data"]["room"]["seats"]["south"]["password"] == false
        end)

      for log <- [log, join_log] do
        assert log =~ "POST /api/v1/rooms"
        refute log =~ ~s("#{password}")
        refute log =~ "seat_password"
      end

      :ok = RoomManager.handle_player_disconnect(code, player.id)
      assert {:ok, reclaimed} = RoomManager.handle_player_reconnect(code, player.id)
      assert reclaimed.positions.south == player.id
      assert reclaimed.config.password_seats == [:south]
      assert reclaimed.config.seat_password == password
    end

    test "the host sets and clears password seats; a held friend sits without one", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      friend = AccountsFixtures.user_fixture()
      stranger = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      host_room = as_user(conn, host) |> get(~p"/api/v1/rooms/#{room.code}") |> json_response(200)
      refute Map.has_key?(host_room["data"]["room"], "seat_password")

      password_seat = %{"seat" => %{"type" => "open", "min_games" => 0, "password" => true}}

      assert as_user(conn, stranger)
             |> put(~p"/api/v1/rooms/#{room.code}/seats/east", password_seat)
             |> json_response(403)

      assert as_user(conn, host)
             |> put(~p"/api/v1/rooms/#{room.code}/seats/north", password_seat)
             |> json_response(422)

      east =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/east", password_seat)
        |> json_response(200)

      password = east["data"]["room"]["seat_password"]
      assert east["data"]["room"]["seats"]["east"]["password"] == true
      assert_received {:readiness_updated, %{seats: %{east: %{password: true}}}}

      south =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/south", password_seat)
        |> json_response(200)

      assert south["data"]["room"]["seat_password"] == password

      cleared =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/east", %{"seat" => "open"})
        |> json_response(200)

      assert cleared["data"]["room"]["seats"]["east"]["password"] == false
      assert cleared["data"]["room"]["seat_password"] == password

      {:ok, _} = RoomManager.set_seat_hold(room.code, host.id, :south, friend.id)

      joined =
        as_user(conn, friend)
        |> post(~p"/api/v1/rooms/#{room.code}/join", %{position: "south"})
        |> json_response(200)

      assert joined["data"]["assigned_position"] == "south"

      {:ok, _, :east} = RoomManager.join_room(room.code, stranger.id, :east)

      {:ok, _} = RoomManager.set_seat(room.code, host.id, :west, {:open, 0, true})

      assert {:error, :seat_requires_password} =
               RoomManager.move_seat(room.code, stranger.id, stranger.id, :west)

      assert {:ok, moved} = RoomManager.move_seat(room.code, host.id, stranger.id, :west)
      assert moved.positions.west == stranger.id
    end

    test "a join that names no seat skips a password seat while an ordinary one is free", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      [auto, team, last] = for _ <- 1..3, do: AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{password_seats: [:east, :south]})
      join = &post(as_user(conn, &1), ~p"/api/v1/rooms/#{room.code}/join", &2)

      assert data(join.(auto, %{}), 200)["assigned_position"] == "west"
      assert json_response(join.(team, %{position: "north_south"}), 403)

      assert data(join.(last, %{password: room.config.seat_password}), 200)["assigned_position"] ==
               "east"
    end

    test "password guesses are limited per player; wrong ones per table, never the right one",
         %{conn: conn} do
      with_limit(:seat_password, 2, 60_000)
      with_limit(:seat_password_room, 2, 60_000)
      host = AccountsFixtures.user_fixture()
      [first, stranger, friend] = for _ <- 1..3, do: AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{password_seats: [:south]})
      password = room.config.seat_password
      wrong = if password == "0000", do: "1111", else: "0000"
      join = &post(as_user(conn, &1), ~p"/api/v1/rooms/#{room.code}/join", &2)

      # Every 429 tells the app the same wait in its body as in its header.
      rate_limited = fn denied ->
        [seconds] = get_resp_header(denied, "retry-after")

        assert %{"error_code" => "rate_limited", "error_params" => %{"retry_after" => wait}} =
                 json_response(denied, 429)

        assert wait == String.to_integer(seconds)
      end

      # A join without a password is no guess and never counts.
      for _ <- 1..3, do: assert(json_response(join.(first, %{position: "south"}), 403))

      for _ <- 1..2,
          do: assert(json_response(join.(first, %{position: "south", password: wrong}), 403))

      # Over the player's limit, even the right password waits.
      rate_limited.(join.(first, %{position: "south", password: password}))

      # The table holds the two wrong guesses: a stranger's next wrong one waits,
      # but a friend with the right password still sits down.
      rate_limited.(join.(stranger, %{position: "south", password: wrong}))
      assert data(join.(friend, %{position: "south", password: password}), 200)

      assert {:ok, %{positions: %{south: south}}} = RoomManager.get_room(room.code)
      assert south == friend.id
    end

    test "a join call that fails logs no typed password" do
      host = AccountsFixtures.user_fixture()
      player = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id)
      password = "typed-7319"
      manager = Process.whereis(RoomManager)
      :sys.suspend(manager)

      try do
        caller = spawn(fn -> RoomManager.join_room(room.code, player, :east, password) end)
        call = queued_join_call(manager)

        # The exit a call timeout gives the caller, as the caller logs it. A
        # room manager crash report prints the same call as its last message.
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            {:ok, pid} =
              Task.start(fn ->
                exit({:timeout, {GenServer, :call, [RoomManager, call, 5000]}})
              end)

            ref = Process.monitor(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, _}
          end)

        assert log =~ ":join_room"
        refute log =~ password
        refute inspect(call) =~ password
        Process.exit(caller, :kill)
      after
        :sys.resume(manager)
      end
    end
  end

  describe "PID-256 set_seat/2" do
    test "an open seat goes 100+, 1000+, password and back to anyone, for everyone", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      viewer = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      steps = [
        {%{"type" => "open", "min_games" => 100}, 100, false},
        {%{"type" => "open", "min_games" => 1000}, 1000, false},
        {%{"type" => "open", "min_games" => 1000, "password" => true}, 1000, true},
        {"open", 0, false}
      ]

      for {{entry, min_games, password?}, epoch} <- Enum.with_index(steps, room.ready_epoch + 1) do
        seat =
          as_user(conn, host)
          |> put(~p"/api/v1/rooms/#{room.code}/seats/east", %{"seat" => entry})
          |> data(200)
          |> get_in(["room", "seats", "east"])

        assert %{"min_games" => ^min_games, "password" => ^password?, "occupant_type" => "vacant"} =
                 seat

        listed =
          as_user(conn, viewer)
          |> get(~p"/api/v1/lobby")
          |> data(200)
          |> Map.fetch!("open_tables")
          |> Enum.find(&(&1["code"] == room.code))

        assert %{"min_games" => ^min_games, "password" => ^password?} = listed["seats"]["east"]

        assert_receive {:readiness_updated,
                        %{ready_epoch: ^epoch, seats: %{east: %{min_games: ^min_games}}}}

        assert_receive {:room_updated, %{code: code}} when code == room.code
      end

      {:ok, final} = RoomManager.get_room(room.code)
      assert final.config.seat_requirements == %{}
      assert final.config.password_seats == []
      assert final.config.solo == false
      assert final.config.seat_password =~ ~r/\A\d{4}\z/

      # The same entry again is no change at all.
      assert as_user(conn, host)
             |> put(~p"/api/v1/rooms/#{room.code}/seats/east", %{"seat" => "open"})
             |> data(200)

      refute_receive {:readiness_updated, _}
      assert {:ok, ^final} = RoomManager.get_room(room.code)
    end

    test "a bot seat opens again and its bot is gone", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      botted =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/west", %{"seat" => "ai"})
        |> data(200)

      assert botted["room"]["positions"]["west"] == "bot_#{room.code}_west"
      pid = BotManager.bot_pid(room.code, :west)
      assert Process.alive?(pid)
      ref = Process.monitor(pid)

      # Bot again is no change and keeps the same bot.
      assert as_user(conn, host)
             |> put(~p"/api/v1/rooms/#{room.code}/seats/west", %{"seat" => "ai"})
             |> data(200)

      assert BotManager.bot_pid(room.code, :west) == pid
      {:ok, before} = RoomManager.get_room(room.code)

      opened =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/west", %{
          "seat" => %{"type" => "open", "min_games" => 100}
        })
        |> data(200)

      assert opened["room"]["positions"]["west"] == nil
      assert %{"occupant_type" => "vacant", "min_games" => 100} = opened["room"]["seats"]["west"]
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert BotManager.bot_pid(room.code, :west) == nil
      refute Map.has_key?(:sys.get_state(RoomManager).player_rooms, "bot_#{room.code}_west")

      epoch = before.ready_epoch + 1
      assert_receive {:readiness_updated, %{ready_epoch: ^epoch, positions: %{west: nil}}}
      assert {:ok, %{seat_lifecycle_revision: revision}} = RoomManager.get_room(room.code)
      assert revision > before.seat_lifecycle_revision
    end

    test "a reopened table's substitute bot stops with its seat", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      departed = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id)
      {:ok, _, :east} = RoomManager.join_room(room.code, departed.id, :east)
      {:ok, pid} = PidroServer.Games.Bots.SubstituteBot.start(room.code, :east)
      ref = Process.monitor(pid)

      # As after a finished game reopens: the departed player's seat keeps its
      # substitute, and the player has since gone to another table.
      :sys.replace_state(RoomManager, fn state ->
        state
        |> update_in([Access.key(:rooms), room.code, Access.key(:seats), :east], fn seat ->
          %{seat | occupant_type: :bot, status: :bot_substitute, bot_pid: pid}
        end)
        |> put_in([Access.key(:player_rooms), departed.id], "ELSE")
      end)

      opened =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/east", %{"seat" => "open"})
        |> data(200)

      assert opened["room"]["positions"]["east"] == nil
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert :sys.get_state(RoomManager).player_rooms[departed.id] == "ELSE"
    end

    test "a held seat becomes a bot in the host's one call, so nobody takes it between" do
      host = AccountsFixtures.user_fixture()
      friend = AccountsFixtures.user_fixture()
      stranger = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{seat_holds: %{east: friend.id}})

      {:ok, botted} = RoomManager.set_seat(room.code, host.id, :east, :bot)
      assert %{occupant_type: :bot, bot_pid: nil} = botted.seats[:east]
      assert botted.positions[:east] == "bot_#{room.code}_east"
      assert botted.config.seat_holds == %{}
      assert {:error, _} = RoomManager.join_room(room.code, stranger.id, :east)

      # The bot's process takes the seat that waits for it.
      {:ok, pid} = BotManager.start_bot(room.code, :east, room.config.bot_difficulty)

      assert {:ok, %{seats: %{east: %{occupant_type: :bot, bot_pid: ^pid}}}} =
               RoomManager.get_room(room.code)
    end

    test "a held seat becomes a bot or another friend, and the invitee hears it went", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      [friend, other_friend] = for _ <- 1..2, do: AccountsFixtures.user_fixture()

      {:ok, room} =
        RoomManager.create_room(host.id, %{seat_holds: %{east: friend.id, south: other_friend.id}})

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:invitations:#{friend.id}")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:invitations:#{other_friend.id}")

      # A friend held in another seat cannot be held here too.
      assert %{"errors" => [%{"code" => "ALREADY_SEATED"}]} =
               as_user(conn, host)
               |> put(~p"/api/v1/rooms/#{room.code}/seats/east", %{
                 "seat" => %{"type" => "held", "user_id" => other_friend.id}
               })
               |> json_response(422)

      botted =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/east", %{"seat" => "ai"})
        |> data(200)

      assert botted["room"]["seats"]["east"]["occupant_type"] == "bot"
      refute Map.has_key?(botted["room"]["seats"]["east"], "held_for")
      friend_id = friend.id

      assert_receive {:seat_invitation_gone, ^friend_id,
                      %{code: code, position: :east, reason: "released"}}
                     when code == room.code

      assert RoomManager.seat_invitations(friend.id) == []

      # The bot seat can be held again, and its bot goes.
      bot = BotManager.bot_pid(room.code, :east)

      held =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/east", %{
          "seat" => %{"type" => "held", "user_id" => friend.id}
        })
        |> data(200)

      assert held["room"]["seats"]["east"]["held_for"]["user_id"] == friend.id
      assert_receive {:seat_invitation, ^friend_id, %{position: :east}}
      refute Process.alive?(bot)

      swapped =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/south", %{
          "seat" => %{"type" => "held", "user_id" => host.id}
        })
        |> json_response(422)

      assert %{"errors" => [%{"code" => "ALREADY_SEATED"}]} = swapped

      third = AccountsFixtures.user_fixture()
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:invitations:#{third.id}")

      rehold =
        as_user(conn, host)
        |> put(~p"/api/v1/rooms/#{room.code}/seats/south", %{
          "seat" => %{"type" => "held", "user_id" => third.id}
        })
        |> data(200)

      assert rehold["room"]["seats"]["south"]["held_for"]["user_id"] == third.id
      other_id = other_friend.id
      third_id = third.id
      assert_receive {:seat_invitation_gone, ^other_id, %{position: :south}}
      assert_receive {:seat_invitation, ^third_id, %{position: :south}}

      assert %{"field_errors" => [%{"field" => "seats"}]} =
               as_user(conn, host)
               |> put(~p"/api/v1/rooms/#{room.code}/seats/south", %{
                 "seat" => %{"type" => "held", "user_id" => Ecto.UUID.generate()}
               })
               |> json_response(422)
    end

    test "a human's seat, a stranger, a playing room and a bad entry are refused", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      player = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id)
      {:ok, _, :east} = RoomManager.join_room(room.code, player.id, :east)
      put_seat = &put(as_user(conn, &1), ~p"/api/v1/rooms/#{room.code}/seats/#{&2}", &3)

      for position <- ["north", "east"] do
        assert %{"errors" => [%{"code" => "SEAT_NOT_VACANT"}]} =
                 json_response(put_seat.(host, position, %{"seat" => "ai"}), 422)
      end

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               json_response(put_seat.(player, "south", %{"seat" => "ai"}), 403)

      assert %{"field_errors" => [%{"field" => "seat"}]} =
               json_response(put_seat.(host, "south", %{"seat" => %{"type" => "open"}}), 422)

      assert json_response(put_seat.(host, "south", %{}), 422)

      :ok = RoomManager.update_room_status(room.code, :playing)

      assert %{"errors" => [%{"code" => "ROOM_NOT_WAITING"}]} =
               json_response(put_seat.(host, "south", %{"seat" => "open"}), 409)

      assert {:ok, %{positions: %{east: east}, seats: %{south: %{occupant_type: :vacant}}}} =
               RoomManager.get_room(room.code)

      assert east == player.id
    end
  end

  describe "PID-79 explicit admission" do
    test "REST Join promotes a watcher only after an opened seat is explicitly claimed", %{
      conn: conn
    } do
      [host, leaver, south, west] =
        Enum.map(1..4, fn _ -> AccountsFixtures.guest_fixture() end)

      watcher = AccountsFixtures.user_fixture()

      {:ok, room} = RoomManager.create_room(host.id)

      for user <- [leaver, south, west],
          do: assert({:ok, _, _} = RoomManager.join_room(room.code, user.id))

      PidroServer.RoomFixtures.ready_room(room.code)
      auth = put_req_header(conn, "authorization", "Bearer #{Token.generate(watcher)}")
      assert json_response(post(auth, ~p"/api/v1/rooms/#{room.code}/watch"), 200)
      assert json_response(post(auth, ~p"/api/v1/rooms/#{room.code}/watch"), 200)
      assert RoomManager.is_spectator?(room.code, watcher.id)
      :ok = RoomManager.leave_room(leaver.id)
      {:ok, _} = RoomManager.open_seat(room.code, :east, host.id)

      # A stale URL may not remove this account's current watch.
      assert json_response(delete(auth, ~p"/api/v1/rooms/OLD1/unwatch"), 404)
      assert RoomManager.is_spectator?(room.code, watcher.id)
      response = post(auth, ~p"/api/v1/rooms/#{room.code}/join") |> json_response(200)
      assert response["data"]["assigned_position"] == "east"
      assert response["data"]["room"]["positions"]["east"] == watcher.id
      refute watcher.id in response["data"]["room"]["spectator_ids"]
      assert response["data"]["room"]["available_positions"] == []
      refute RoomManager.is_spectator?(room.code, watcher.id)
    end

    test "with watching tables off, Watch answers as for a room nobody may watch", %{conn: conn} do
      on_exit(fn -> Application.put_env(:pidro_server, :watching_tables, true) end)
      Application.put_env(:pidro_server, :watching_tables, false)
      [host | others] = Enum.map(1..4, fn _ -> AccountsFixtures.guest_fixture() end)
      {:ok, room} = RoomManager.create_room(host.id)
      for user <- others, do: assert({:ok, _, _} = RoomManager.join_room(room.code, user.id))
      PidroServer.RoomFixtures.ready_room(room.code)
      auth = as_user(conn, AccountsFixtures.user_fixture())

      assert %{"errors" => [%{"code" => "ROOM_NOT_AVAILABLE_FOR_SPECTATORS"} = error]} =
               auth |> post(~p"/api/v1/rooms/#{room.code}/watch") |> json_response(422)

      assert error["title"] == "Room not available for spectators"
      assert %{"spectatable" => []} = auth |> get(~p"/api/v1/lobby") |> data(200)
    end

    test "a guest watcher cannot claim an opened substitute seat", %{conn: conn} do
      [host, leaver, south, west, watcher] =
        Enum.map(1..5, fn _ -> AccountsFixtures.guest_fixture() end)

      {:ok, room} = RoomManager.create_room(host.id)

      for user <- [leaver, south, west],
          do: assert({:ok, _, _} = RoomManager.join_room(room.code, user.id))

      PidroServer.RoomFixtures.ready_room(room.code)
      auth = as_user(conn, watcher)
      assert json_response(post(auth, ~p"/api/v1/rooms/#{room.code}/watch"), 200)
      :ok = RoomManager.leave_room(leaver.id)
      {:ok, _} = RoomManager.open_seat(room.code, :east, host.id)

      assert %{"errors" => [%{"code" => "ACCOUNT_REQUIRED"}]} =
               auth
               |> post(~p"/api/v1/rooms/#{room.code}/join")
               |> json_response(403)

      assert RoomManager.is_spectator?(room.code, watcher.id)
      assert {:ok, updated} = RoomManager.get_room(room.code)
      assert updated.seats.east.occupant_type == :vacant

      state = :sys.get_state(RoomManager)
      assert state.spectator_rooms[watcher.id] == room.code
      refute Map.has_key?(state.player_rooms, watcher.id)
    end
  end

  describe "leave/2" do
    test "returns 204 and transfers the running seat to a bot", %{conn: conn} do
      [host, leaver, south, west] = Enum.map(1..4, fn _ -> AccountsFixtures.guest_fixture() end)
      {:ok, room} = RoomManager.create_room(host.id, %{})
      assert {:ok, _, position} = RoomManager.join_room(room.code, leaver.id)

      for user <- [south, west],
          do: assert({:ok, _, _} = RoomManager.join_room(room.code, user.id))

      PidroServer.RoomFixtures.ready_room(room.code)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(leaver)}")
        |> delete(~p"/api/v1/rooms/#{room.code}/leave")

      assert response(conn, 204)
      assert {:ok, updated} = RoomManager.get_room(room.code)
      assert updated.status == :playing
      assert updated.seats[position].status == :bot_substitute
      assert Process.alive?(updated.seats[position].bot_pid)
    end

    test "a late leave for a finished table leaves the player's new table alone",
         %{conn: conn} do
      [player, other] = Enum.map(1..2, fn _ -> AccountsFixtures.guest_fixture() end)
      {:ok, finished} = RoomManager.create_room(other.id, %{})
      {:ok, _, _} = RoomManager.join_room(finished.code, player.id)
      :ok = RoomManager.update_room_status(finished.code, :finished)
      :ok = RoomManager.leave_room(player.id)
      {:ok, room} = RoomManager.create_room(player.id, %{solo: true})

      conn = leave(conn, player, finished.code)

      assert json_response(conn, 404) == %{
               "error_code" => "not_in_room",
               "error_params" => %{},
               "errors" => [
                 %{
                   "code" => "NOT_IN_ROOM",
                   "title" => "Not in room",
                   "detail" => "Player is not in any room"
                 }
               ]
             }

      assert {:ok, _} = RoomManager.get_room(room.code)
      assert :sys.get_state(RoomManager).player_rooms[player.id] == room.code
    end

    test "current leaves whichever table the player is at", %{conn: conn} do
      player = AccountsFixtures.guest_fixture()
      {:ok, room} = RoomManager.create_room(player.id, %{})

      assert response(leave(conn, player, "current"), 204)
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "current with no table answers not in room", %{conn: conn} do
      player = AccountsFixtures.guest_fixture()

      conn = leave(conn, player, "current")

      assert %{"errors" => [%{"code" => "NOT_IN_ROOM"}]} = json_response(conn, 404)
    end

    test "the player's own table by code, in any case", %{conn: conn} do
      [host, player] = Enum.map(1..2, fn _ -> AccountsFixtures.guest_fixture() end)
      {:ok, room} = RoomManager.create_room(host.id, %{})
      {:ok, _, _} = RoomManager.join_room(room.code, player.id)

      assert response(leave(conn, player, String.downcase(room.code)), 204)
      refute Map.has_key?(:sys.get_state(RoomManager).player_rooms, player.id)
      assert {:ok, _} = RoomManager.get_room(room.code)
    end

    defp leave(conn, user, code) do
      conn
      |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
      |> delete(~p"/api/v1/rooms/#{code}/leave")
    end
  end

  describe "create/2" do
    test "rule_set grammar and serialized payload", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      for {body, expected} <- [
            {%{}, "finnish"},
            {%{"rule_set" => "finnish"}, "finnish"},
            {%{"rule_set" => "louisiana"}, "louisiana"}
          ] do
        response = conn |> as_user(user) |> post(~p"/api/v1/rooms", body) |> data(201)
        assert response["room"]["config"]["rule_set"] == expected
        RoomManager.reset_for_test()
      end

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{"rule_set" => "garbage"})
        |> json_response(422)

      assert %{
               "errors" => [
                 %{"code" => "rule_set", "detail" => "must be one of: finnish, louisiana"}
               ]
             } = response
    end

    test "room payloads never expose private account fields", %{conn: conn} do
      host = AccountsFixtures.user_fixture()

      host =
        host
        |> Ecto.Changeset.change(%{
          age_band: "18_plus",
          age_declared_at: DateTime.utc_now(),
          terms_version: "1",
          terms_accepted_at: DateTime.utc_now(),
          classic_user_id: 987_654,
          classic_claimed_at: DateTime.utc_now(),
          classic_claim_method: :apple,
          classic_matched_on: :email,
          apple_sub: "private-apple-subject"
        })
        |> PidroServer.Repo.update!()

      {:ok, _host} =
        UserIdentities.link(
          host,
          %{
            provider: :apple,
            subject: "private-apple-subject",
            issuer_app: "private-issuer-app",
            email: "private-identity@example.com",
            email_is_relay: false,
            business_ids: []
          },
          :claim
        )

      room =
        conn
        |> as_user(host)
        |> post(~p"/api/v1/rooms", %{})
        |> data(201)
        |> Map.fetch!("room")

      north = room["seats"]["north"]
      assert north["username"] == host.username
      refute Map.has_key?(north, "age_band")
      refute Map.has_key?(north, "terms_version")
      refute Jason.encode!(room) =~ "age_band"
      refute Jason.encode!(room) =~ "terms_version"
      refute Jason.encode!(room) =~ "private-apple-subject"
      refute Jason.encode!(room) =~ "private-issuer-app"
      refute Jason.encode!(room) =~ "private-identity@example.com"
      refute Jason.encode!(room) =~ "classic_matched_on"
    end

    test "a guest can host an open friends table", %{conn: conn} do
      guest = AccountsFixtures.guest_fixture()

      assert %{"code" => code, "room" => room} =
               conn
               |> as_user(guest)
               |> post(~p"/api/v1/rooms", %{})
               |> data(201)

      assert room["host_id"] == guest.id
      assert room["positions"]["north"] == guest.id
      assert room["seats"]["north"]["user_id"] == guest.id
      assert mapped_room_code(guest) == code
    end

    test "AE3: three ai seats answer 201 with a solo config, three bot seats, and no lobby listing",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> post(~p"/api/v1/rooms", %{
          "name" => "Solo Table",
          "seats" => %{
            "seat_2" => "ai",
            "seat_3" => "ai",
            "seat_4" => "ai"
          },
          "bot_difficulty" => "basic"
        })

      data = json_response(conn, 201)["data"]
      code = data["code"]

      assert data["room"]["seats"]["north"]["username"] == user.username

      shown =
        build_conn()
        |> get(~p"/api/v1/rooms/#{code}")
        |> json_response(200)
        |> get_in(["data", "room", "seats"])

      bot_seats =
        shown
        |> Map.values()
        |> Enum.filter(&(&1["occupant_type"] == "bot"))

      assert bot_seats |> Enum.map(& &1["bot_persona"]) |> Enum.sort() ==
               ["antti", "jocke", "marcel"]

      for seat <- bot_seats do
        assert seat["is_bot"] == true

        assert seat["avatar_url"] ==
                 PidroServerWeb.Endpoint.url() <> "/images/bots/#{seat["bot_persona"]}.svg"

        assert seat["bot_profile"]["id"] == seat["bot_persona"]
        assert seat["display_name"] == String.capitalize(seat["bot_persona"])
        assert seat["username"] == seat["display_name"]
      end

      assert shown["north"]["is_bot"] == false
      assert shown["north"]["bot_persona"] == nil

      assert {:ok, room} = RoomManager.get_room(code)
      assert room.config.solo == true

      assert data["room"]["config"] == %{
               "name" => "Solo Table",
               "bot_difficulty" => "basic",
               "rule_set" => "finnish",
               "solo" => true
             }

      for position <- [:east, :south, :west] do
        assert room.seats[position].occupant_type == :bot
      end

      assert BotManager.list_bots(code) |> Map.keys() |> Enum.sort() == [:east, :south, :west]

      listed =
        build_conn()
        |> get(~p"/api/v1/rooms")
        |> json_response(200)
        |> get_in(["data", "rooms"])
        |> Enum.map(& &1["code"])

      refute code in listed
    end

    for {label, legacy_value, extra_params} <- [
          {"omitted", :basic, %{}},
          {"random", :random, %{"bot_difficulty" => "random"}},
          {"basic", :basic, %{"bot_difficulty" => "basic"}},
          {"smart", :smart, %{"bot_difficulty" => "smart"}}
        ] do
      test "an all-AI create with difficulty #{label} seats characters on their own strategy",
           %{conn: conn} do
        user = AccountsFixtures.user_fixture()

        params =
          Map.merge(
            %{"seats" => %{"seat_2" => "ai", "seat_3" => "ai", "seat_4" => "ai"}},
            unquote(Macro.escape(extra_params))
          )

        data =
          conn
          |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
          |> post(~p"/api/v1/rooms", params)
          |> json_response(201)
          |> Map.fetch!("data")

        assert {:ok, room} = RoomManager.get_room(data["code"])

        assert room.config == %Config{
                 name: nil,
                 bot_difficulty: unquote(legacy_value),
                 solo: true
               }

        bots = for {_, %{occupant_type: :bot, bot_pid: pid}} <- room.seats, do: pid
        assert length(bots) == 3

        # The seeded crew plays search (PID-403), whatever the legacy difficulty says.
        for pid <- bots,
            do:
              assert(
                :sys.get_state(pid).strategy == PidroServer.Games.Bots.Strategies.SearchStrategy
              )
      end
    end

    test "AE4: a named room with one bot seat reports name, difficulty and not solo", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture()

      data =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> post(~p"/api/v1/rooms", %{
          "name" => "Friday",
          "seats" => %{"seat_2" => "ai"},
          "bot_difficulty" => "smart"
        })
        |> json_response(201)
        |> Map.fetch!("data")

      expected = %{
        "name" => "Friday",
        "bot_difficulty" => "smart",
        "rule_set" => "finnish",
        "solo" => false
      }

      assert data["room"]["config"] == expected
      refute Map.has_key?(data["room"], "metadata")

      # The room show endpoint reports the same object.
      shown = conn |> get(~p"/api/v1/rooms/#{data["code"]}") |> json_response(200)
      assert shown["data"]["room"]["config"] == expected

      assert {:ok, room} = RoomManager.get_room(data["code"])
      assert room.seats.east.occupant_type == :bot
    end

    test "a 61-character name is a 422 naming name, and no room is created", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> post(~p"/api/v1/rooms", %{"name" => String.duplicate("n", 61)})
        |> json_response(422)

      assert %{
               "errors" => [
                 %{
                   "code" => "name",
                   "title" => "Name",
                   "detail" => "must be at most 60 characters"
                 }
               ]
             } = response

      refute Enum.any?(RoomManager.list_rooms(:all), &(&1.host_id == user.id))
    end

    test "AE1: a create with settings is a 422 naming settings, and the host is mapped to no room",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{
          "name" => "Legacy client",
          "settings" => %{"min_games" => 1, "time_limit" => 0, "private" => false}
        })
        |> json_response(422)

      assert %{
               "errors" => [
                 %{"code" => "settings", "title" => "Settings", "detail" => detail} | _
               ]
             } = response

      assert detail == "is not an accepted field"
      assert_no_room_for(user)
    end

    test "AE2: bot_difficulty expert is a 422 naming bot_difficulty, and no bot process was started",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      bots_before = bot_pids()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{
          "seats" => %{"seat_2" => "ai"},
          "bot_difficulty" => "expert"
        })
        |> json_response(422)

      assert %{"errors" => [%{"code" => "bot_difficulty"} | _]} = response
      assert MapSet.subset?(bot_pids(), bots_before)
      assert_no_room_for(user)
    end

    test "AE2: one ai seat and no difficulty answers 201 with a config difficulty of basic", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture()

      data =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{"seats" => %{"seat_3" => "ai"}})
        |> data(201)

      assert data["room"]["config"]["bot_difficulty"] == "basic"
      assert data["room"]["config"]["solo"] == false

      # The bot sits where the seat plan says and runs the config's difficulty.
      assert %{south: %{strategy: :basic}} = bots = BotManager.list_bots(data["code"])
      assert Map.keys(bots) == [:south]
    end

    test "a create wrapped in room is a 422 naming room", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{"room" => %{"name" => "Wrapped"}})
        |> json_response(422)

      assert %{"errors" => [%{"code" => "room"}]} = response
      assert_no_room_for(user)
    end

    test "a create with seats.seat_5 is a 422 naming seats.seat_5", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{"seats" => %{"seat_2" => "ai", "seat_5" => "ai"}})
        |> json_response(422)

      assert %{
               "errors" => [
                 %{
                   "code" => "seats.seat_5",
                   "title" => "Seats seat 5",
                   "detail" => "is not an accepted field"
                 }
               ]
             } = response

      assert_no_room_for(user)
    end

    test "settings and an unknown difficulty together are a 422 with two entries naming both", %{
      conn: conn
    } do
      user = AccountsFixtures.user_fixture()

      response =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms", %{
          "name" => "Legacy client",
          "settings" => %{"min_games" => 1, "time_limit" => 0, "private" => false},
          "bot_difficulty" => "expert"
        })
        |> json_response(422)

      assert %{"errors" => [_first, _second] = errors} = response
      assert errors |> Enum.map(& &1["code"]) |> Enum.sort() == ["bot_difficulty", "settings"]
      assert response["error_code"] == "validation_failed"
      assert response["error_params"] == %{}

      assert Enum.sort_by(response["field_errors"], & &1["field"]) == [
               %{
                 "field" => "bot_difficulty",
                 "error_code" => "field_invalid",
                 "error_params" => %{}
               },
               %{"field" => "settings", "error_code" => "field_invalid", "error_params" => %{}}
             ]

      assert_no_room_for(user)
    end

    test "an unknown query-string parameter beside a valid body answers 201", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> as_user(user)
        |> post(~p"/api/v1/rooms?#{[ref: "campaign"]}", %{"name" => "From a link"})

      assert data(conn, 201)["room"]["config"]["name"] == "From a link"

      # The query-string key reaches the merged params but not the parsed body.
      assert conn.params["ref"] == "campaign"
      assert conn.body_params == %{"name" => "From a link"}
    end

    test "an empty body answers 201 with the default config", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      conn = conn |> as_user(user) |> post(~p"/api/v1/rooms")

      assert data(conn, 201)["room"]["config"] == %{
               "name" => nil,
               "bot_difficulty" => "basic",
               "rule_set" => "finnish",
               "solo" => false
             }

      assert conn.body_params == %{}
    end

    test "an empty application/json body answers 201 with the default config", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> as_user(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/rooms", "")

      assert data(conn, 201)["room"]["config"]["bot_difficulty"] == "basic"
      assert conn.body_params == %{}
    end

    test "a raw JSON object body is parsed from string-keyed body_params", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      body =
        Jason.encode!(%{
          name: "Raw",
          seats: %{seat_2: "ai", seat_4: "open"},
          bot_difficulty: "random"
        })

      conn =
        conn
        |> as_user(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/rooms", body)

      data = data(conn, 201)

      assert conn.body_params == %{
               "name" => "Raw",
               "seats" => %{"seat_2" => "ai", "seat_4" => "open"},
               "bot_difficulty" => "random"
             }

      assert data["room"]["config"] == %{
               "name" => "Raw",
               "bot_difficulty" => "random",
               "rule_set" => "finnish",
               "solo" => false
             }

      assert %{east: %{strategy: :random}} = BotManager.list_bots(data["code"])
    end

    test "a non-object JSON body is a 422 naming body, not a 500", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> as_user(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/rooms", ~s(["name", "settings"]))

      assert %{"errors" => [%{"code" => "body", "detail" => "must be a JSON object"}]} =
               json_response(conn, 422)

      assert conn.body_params == %{"_json" => ["name", "settings"]}
      assert_no_room_for(user)
    end

    # Plug wraps only non-object JSON as `_json`, so a `_json` key holding an
    # object is one the caller sent. It is an unknown field like any other.
    test "a literal _json wrapper is rejected naming _json and creates no room", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> as_user(user)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/rooms", ~s({"_json": {"name": "Friday"}}))

      assert %{"errors" => [%{"code" => "_json", "detail" => "is not an accepted field"}]} =
               json_response(conn, 422)

      assert conn.body_params == %{"_json" => %{"name" => "Friday"}}
      assert_no_room_for(user)
    end

    test "a rejected create leaves the caller's existing room mapping untouched", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Held"})

      # A held seat is what a valid create would evict (it closes the old room).
      :ok = RoomManager.handle_player_disconnect(room.code, host.id)
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")

      response =
        conn
        |> as_user(host)
        |> post(~p"/api/v1/rooms", %{"name" => "Next", "settings" => %{"private" => true}})
        |> json_response(422)

      assert %{"errors" => [%{"code" => "settings"}]} = response

      assert {:ok, held} = RoomManager.get_room(room.code)
      assert held.host_id == host.id
      assert held.positions.north == host.id
      assert mapped_room_code(host) == room.code
      refute_receive {:room_closed, _code}, 100
      assert [%{code: code}] = RoomManager.list_rooms(:all)
      assert code == room.code
    end

    test "returns 503 ROOM_CODE_EXHAUSTED when no free room code can be allocated", %{
      conn: conn
    } do
      original = Application.get_env(:pidro_server, RoomCodes)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pidro_server, RoomCodes, original),
          else: Application.delete_env(:pidro_server, RoomCodes)
      end)

      # Every draw yields the code already held by another room
      Application.put_env(:pidro_server, RoomCodes, generator: fn -> "ZZZZ" end)
      holder = AccountsFixtures.user_fixture()
      {:ok, %{code: "ZZZZ"}} = RoomManager.create_room(holder.id, %{name: "Held"})

      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
        |> post(~p"/api/v1/rooms", %{"name" => "Crowded"})

      assert %{"errors" => [%{"code" => "ROOM_CODE_EXHAUSTED"}]} = json_response(conn, 503)

      assert {:ok, held} = RoomManager.get_room("ZZZZ")
      assert held.host_id == holder.id
    end
  end

  describe "index/2" do
    test "excludes single-player rooms from the public lobby list", %{conn: conn} do
      solo_host = AccountsFixtures.user_fixture()
      public_host = AccountsFixtures.user_fixture()

      {:ok, solo_room} =
        RoomManager.create_room(solo_host.id, %{name: "Solo", solo: true})

      {:ok, public_room} = RoomManager.create_room(public_host.id, %{name: "Public"})

      rooms =
        conn
        |> get(~p"/api/v1/rooms")
        |> json_response(200)
        |> get_in(["data", "rooms"])

      codes = Enum.map(rooms, & &1["code"])
      serialized_public_room = Enum.find(rooms, &(&1["code"] == public_room.code))

      assert public_room.code in codes
      refute solo_room.code in codes
      assert serialized_public_room["seats"]["north"]["username"] == public_host.username
    end
  end

  describe "lobby/2" do
    test "excludes solo rooms from every lobby category", %{conn: conn} do
      solo_host = AccountsFixtures.user_fixture()
      public_host = AccountsFixtures.user_fixture()
      viewer = AccountsFixtures.user_fixture()

      {:ok, solo_room} = RoomManager.create_room(solo_host.id, %{name: "Solo", solo: true})
      {:ok, public_room} = RoomManager.create_room(public_host.id, %{name: "Public"})

      lobby =
        conn
        |> put_req_header("authorization", "Bearer #{Token.generate(viewer)}")
        |> get(~p"/api/v1/lobby")
        |> json_response(200)
        |> Map.fetch!("data")

      codes = lobby |> Map.values() |> List.flatten() |> Enum.map(& &1["code"])
      open_table = Enum.find(lobby["open_tables"], &(&1["code"] == public_room.code))

      assert public_room.code in codes
      refute solo_room.code in codes

      assert open_table["config"] == %{
               "name" => "Public",
               "bot_difficulty" => "basic",
               "rule_set" => "finnish",
               "solo" => false
             }
    end
  end

  describe "rate limiting" do
    # Shares the node-wide Hammer ETS table (reset by RateLimitCase before each
    # test); the module is already async: false.
    test "room_create at limit 1: the same user's second POST /rooms is 429, another user is allowed",
         %{conn: conn} do
      with_limit(:room_create, 1, 60_000)
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()

      assert conn |> create_room_as(user, {10, 2, 0, 1}) |> json_response(201)

      # A different address does not help: the bucket is the user id.
      denied = build_conn() |> create_room_as(user, {10, 2, 0, 2})
      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
      assert [_retry_after] = get_resp_header(denied, "retry-after")

      assert build_conn() |> create_room_as(other, {10, 2, 0, 1}) |> json_response(201)
    end

    test "room_lookup at limit 1: the second GET /rooms/:code from one IP is 429 whether or not the code exists",
         %{conn: conn} do
      with_limit(:room_lookup, 1, 60_000)
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Lookup"})

      assert conn
             |> from_ip({10, 2, 0, 3})
             |> get(~p"/api/v1/rooms/#{room.code}")
             |> json_response(200)

      assert build_conn()
             |> from_ip({10, 2, 0, 3})
             |> get(~p"/api/v1/rooms/ZZZZ")
             |> json_response(429)

      assert build_conn()
             |> from_ip({10, 2, 0, 4})
             |> get(~p"/api/v1/rooms/ZZZZ")
             |> json_response(404)

      assert build_conn()
             |> from_ip({10, 2, 0, 4})
             |> get(~p"/api/v1/rooms/#{room.code}")
             |> json_response(429)
    end

    test "GET /rooms is never limited, even at limit 0", %{conn: conn} do
      with_all_limits(0)
      host = AccountsFixtures.user_fixture()
      {:ok, _room} = RoomManager.create_room(host.id, %{name: "Open"})

      assert conn |> from_ip({10, 2, 0, 5}) |> get(~p"/api/v1/rooms") |> json_response(200)

      assert build_conn()
             |> from_ip({10, 2, 0, 5})
             |> get(~p"/api/v1/rooms")
             |> json_response(200)
    end

    test "room_join at limit 1: the same user's second POST /rooms/:code/join is 429 (R28)", %{
      conn: conn
    } do
      with_limit(:room_join, 1, 60_000)
      host = AccountsFixtures.user_fixture()
      joiner = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Open"})

      assert conn
             |> from_ip({10, 2, 0, 6})
             |> as_user(joiner)
             |> post(~p"/api/v1/rooms/#{room.code}/join", %{})
             |> json_response(200)

      # A different address does not help: the bucket is the user id.
      denied =
        build_conn()
        |> from_ip({10, 2, 0, 7})
        |> as_user(joiner)
        |> post(~p"/api/v1/rooms/#{room.code}/join", %{})

      assert %{"errors" => [%{"code" => "RATE_LIMITED"}]} = json_response(denied, 429)
    end
  end

  describe "index/2 with invites" do
    test "R24: a room with a live invite stays in the public list", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Invited"})
      {:ok, invite} = create_invite(room, host)
      :ok = RoomManager.note_invite(room.code, invite.expires_at)

      rooms =
        conn
        |> get(~p"/api/v1/rooms")
        |> json_response(200)
        |> get_in(["data", "rooms"])

      assert listed = Enum.find(rooms, &(&1["code"] == room.code))
      assert listed["locked"] == false
    end
  end

  describe "seat/2" do
    test "the host moves a player to a vacant seat and the room carries locked and display names",
         %{conn: conn} do
      host = AccountsFixtures.user_fixture(%{display_name: "Marcel"})
      guest = AccountsFixtures.guest_fixture(%{display_name: "Ben"})
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Seats"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, guest.id)

      response =
        conn
        |> as_user(host)
        |> post(~p"/api/v1/rooms/#{room.code}/seat", %{
          "position" => "west",
          "user_id" => guest.id
        })
        |> json_response(200)

      assert %{"room" => room_json} = response["data"]
      assert room_json["locked"] == false
      assert room_json["positions"]["west"] == guest.id
      assert room_json["positions"]["east"] == nil
      assert room_json["seats"]["west"]["display_name"] == "Ben"
      assert room_json["seats"]["west"]["username"] == guest.username
      assert room_json["seats"]["north"]["display_name"] == "Marcel"
    end

    test "a seated non-host may move only themselves", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      mover = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Seats"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, mover.id)
      {:ok, _room, :south} = RoomManager.join_room(room.code, other.id)

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> as_user(mover)
               |> post(~p"/api/v1/rooms/#{room.code}/seat", %{
                 "position" => "west",
                 "user_id" => other.id
               })
               |> json_response(403)

      assert %{"room" => %{"positions" => %{"west" => west}}} =
               build_conn()
               |> as_user(mover)
               |> post(~p"/api/v1/rooms/#{room.code}/seat", %{"position" => "west"})
               |> data(200)

      assert west == mover.id
    end

    test "a taken target seat is 422 SEAT_TAKEN and a bad position is 422 INVALID_POSITION", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      guest = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Seats"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, guest.id)

      assert %{"errors" => [%{"code" => "SEAT_TAKEN"}]} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/seat", %{
                 "position" => "east",
                 "user_id" => host.id
               })
               |> json_response(422)

      assert %{"errors" => [%{"code" => "INVALID_POSITION"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/seat", %{"position" => "up"})
               |> json_response(422)
    end
  end

  describe "lock/2" do
    test "AE12: a locked table refuses joins with 423 until the host unlocks it", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      chris = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Locked"})

      assert %{"room" => %{"locked" => true}} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => true})
               |> data(200)

      assert %{"errors" => [%{"code" => "TABLE_LOCKED"}]} =
               build_conn()
               |> as_user(chris)
               |> post(~p"/api/v1/rooms/#{room.code}/join", %{})
               |> json_response(423)

      assert %{"room" => %{"locked" => false}} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => false})
               |> data(200)

      assert build_conn()
             |> as_user(chris)
             |> post(~p"/api/v1/rooms/#{room.code}/join", %{})
             |> json_response(200)
    end

    test "a non-host gets 403, a playing room 409 ROOM_NOT_WAITING and a non-boolean 422", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Locked"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, other.id)

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> as_user(other)
               |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => true})
               |> json_response(403)

      assert build_conn()
             |> as_user(host)
             |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => "yes"})
             |> json_response(422)

      :ok = RoomManager.update_room_status(room.code, :playing)

      assert %{"errors" => [%{"code" => "ROOM_NOT_WAITING"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/lock", %{"locked" => true})
               |> json_response(409)
    end
  end

  describe "kick/2" do
    test "AE11: the host kicks a seat, it is vacant, and the kicked user cannot join again", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      ben = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Kick"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, ben.id)

      assert %{"room" => %{"positions" => %{"east" => nil}}} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/kick", %{"position" => "east"})
               |> data(200)

      assert %{"errors" => [%{"code" => "KICKED"}]} =
               build_conn()
               |> as_user(ben)
               |> post(~p"/api/v1/rooms/#{room.code}/join", %{})
               |> json_response(403)
    end

    test "a non-host gets 403, the host's own seat 422 SEAT_NOT_KICKABLE and a playing room 409",
         %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Kick"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, other.id)

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> as_user(other)
               |> post(~p"/api/v1/rooms/#{room.code}/kick", %{"position" => "north"})
               |> json_response(403)

      assert %{"errors" => [%{"code" => "SEAT_NOT_KICKABLE"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/kick", %{"position" => "north"})
               |> json_response(422)

      :ok = RoomManager.update_room_status(room.code, :playing)

      assert %{"errors" => [%{"code" => "ROOM_NOT_WAITING"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/kick", %{"position" => "east"})
               |> json_response(409)
    end
  end

  describe "seat_bot/2" do
    test "the host seats a bot in an open seat at the room's difficulty", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Bot seat", bot_difficulty: :smart})

      assert %{"room" => %{"positions" => %{"east" => bot_id}}} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "east"})
               |> data(200)

      assert bot_id == "bot_#{room.code}_east"
      {:ok, seated} = RoomManager.get_room(room.code)
      assert %{occupant_type: :bot, status: :connected, bot_pid: pid} = seated.seats.east
      assert Process.alive?(pid)
      assert %{east: %{strategy: :smart}} = BotManager.list_bots(room.code)
    end

    test "a slot left behind by a bot that is gone does not block the seat", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Bot seat"})
      gone = spawn(fn -> :ok end)
      ref = Process.monitor(gone)
      assert_receive {:DOWN, ^ref, :process, ^gone, _}
      :ets.insert(:pidro_bots, {{room.code, :east}, gone})

      assert %{"room" => %{"positions" => %{"east" => "bot_" <> _}}} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "east"})
               |> data(200)

      assert Process.alive?(BotManager.bot_pid(room.code, :east))
    end

    test "a slot held by a live bot is another request's seat, and that bot is left alone", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Bot seat"})
      other = spawn(fn -> Process.sleep(:infinity) end)
      :ets.insert(:pidro_bots, {{room.code, :east}, other})

      on_exit(fn ->
        :ets.delete(:pidro_bots, {room.code, :east})
        if Process.alive?(other), do: Process.exit(other, :kill)
      end)

      assert %{"errors" => [%{"code" => "SEAT_NOT_VACANT"}]} =
               conn
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "east"})
               |> json_response(422)

      assert Process.alive?(other)
      assert BotManager.bot_pid(room.code, :east) == other
    end

    test "a non-host gets 403, a taken seat 422 SEAT_NOT_VACANT and a playing room 409", %{
      conn: conn
    } do
      host = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Bot seat"})
      {:ok, _room, :east} = RoomManager.join_room(room.code, other.id)

      assert %{"errors" => [%{"code" => "NOT_OWNER"}]} =
               conn
               |> as_user(other)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "south"})
               |> json_response(403)

      assert %{"errors" => [%{"code" => "SEAT_NOT_VACANT"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "east"})
               |> json_response(422)

      :ok = RoomManager.update_room_status(room.code, :playing)

      assert %{"errors" => [%{"code" => "ROOM_NOT_WAITING"}]} =
               build_conn()
               |> as_user(host)
               |> post(~p"/api/v1/rooms/#{room.code}/bot", %{"position" => "south"})
               |> json_response(409)
    end
  end

  describe "join/2 contract" do
    test "an already seated guest keeps the existing error", %{conn: conn} do
      guest = AccountsFixtures.guest_fixture()
      {:ok, room} = RoomManager.create_room(guest.id, %{name: "Friends"})

      assert %{"errors" => [%{"code" => "ALREADY_SEATED"}]} =
               conn
               |> as_user(guest)
               |> post(~p"/api/v1/rooms/#{room.code}/join")
               |> json_response(422)
    end

    test "a guest cannot join an open table by room code", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      guest = AccountsFixtures.guest_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Open"})

      assert %{
               "errors" => [
                 %{
                   "code" => "ACCOUNT_REQUIRED",
                   "title" => "Account required",
                   "detail" => "Create an account to join an open seat"
                 }
               ]
             } =
               conn
               |> as_user(guest)
               |> post(~p"/api/v1/rooms/#{room.code}/join", %{"position" => "south"})
               |> json_response(403)

      assert {:ok, unchanged} = RoomManager.get_room(room.code)
      assert unchanged.positions == %{north: host.id, east: nil, south: nil, west: nil}
      assert mapped_room_code(guest) == nil
    end

    test "a taken explicit seat still answers 422 SEAT_TAKEN", %{conn: conn} do
      host = AccountsFixtures.user_fixture()
      joiner = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Join"})

      assert %{"errors" => [%{"code" => "SEAT_TAKEN"}]} =
               conn
               |> as_user(joiner)
               |> post(~p"/api/v1/rooms/#{room.code}/join", %{"position" => "north"})
               |> json_response(422)
    end
  end

  defp as_user(conn, user) do
    put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")
  end

  defp data(conn, status), do: json_response(conn, status)["data"]

  # The room code RoomManager tracks the user in, or nil.
  defp mapped_room_code(user), do: :sys.get_state(RoomManager).player_rooms[user.id]

  defp assert_no_room_for(user) do
    assert mapped_room_code(user) == nil
    assert {:error, :not_in_room} = RoomManager.leave_room(user.id)
    refute Enum.any?(RoomManager.list_rooms(:all), &(&1.host_id == user.id))
  end

  # Every bot process alive under the bot supervisor, whatever room it serves.
  defp bot_pids do
    BotSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.filter(&is_pid/1)
    |> MapSet.new()
  end

  defp create_invite(room, host) do
    PidroServer.Invites.create_invite(%{
      room_id: room.id,
      room_code: room.code,
      host_user_id: host.id
    })
  end

  defp create_room_as(conn, user, ip) do
    conn
    |> from_ip(ip)
    |> put_req_header("authorization", "Bearer #{Token.generate(user)}")
    |> post(~p"/api/v1/rooms", %{"name" => "Limited"})
  end

  defp queued_join_call(manager) do
    {:messages, messages} = Process.info(manager, :messages)

    case for({:"$gen_call", _from, {:join_room, _, _, _, _, _} = call} <- messages, do: call) do
      [call] -> call
      [] -> queued_join_call(manager)
    end
  end
end
