defmodule PidroServerWeb.API.FriendControllerTest do
  use PidroServerWeb.ConnCase, async: false
  use PidroServerWeb.RateLimitCase

  import PidroServer.AccountsFixtures
  alias PidroServer.Accounts.Token
  alias PidroServer.Blocks
  alias PidroServer.Friends
  alias PidroServer.Games.RoomManager
  alias PidroServerWeb.Presence

  test "Classic count includes only distinct outgoing friends who have not claimed", %{conn: conn} do
    a = user_fixture()
    b = user_fixture()

    assert {:ok, %{ticket: ticket}} =
             PidroServer.Accounts.ClassicClaims.issue_ticket(%{
               classic_user_id: 30_001,
               method: :password,
               user_id: a.id,
               legacy_data: %{
                 friend_ids: [30_002, 30_002, 30_003],
                 friended_by_ids: [30_004],
                 blocked_ids: [30_005]
               }
             })

    assert {:ok, _} = PidroServer.Accounts.ClassicClaims.redeem(ticket, a, %{})
    response = conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response["data"]["classic"] == %{"not_here" => 2}

    response = conn |> auth(b) |> get(~p"/api/v1/friends") |> json_response(200)
    refute Map.has_key?(response["data"], "classic")

    assert {:ok, %{ticket: ticket}} =
             PidroServer.Accounts.ClassicClaims.issue_ticket(%{
               classic_user_id: 30_002,
               method: :password,
               user_id: b.id,
               legacy_data: %{}
             })

    assert {:ok, _} = PidroServer.Accounts.ClassicClaims.redeem(ticket, b, %{})
    response = conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200)
    assert response["data"]["classic"] == %{"not_here" => 1}
    response = conn |> auth(b) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response["data"]["classic"] == %{"not_here" => 0}
    assert response["data"]["added_you"] == [request(a, b)]
  end

  test "HTTP add, add back, list and remove share the full-list contract", %{conn: conn} do
    a = user_fixture(%{display_name: "Nora"})
    b = user_fixture(%{display_name: "Vera"})

    empty = %{
      "data" => %{
        "friends" => [],
        "added_you" => [],
        "requested" => [],
        "requests_waiting" => 0,
        "waiting_for_you" => 0
      }
    }

    response = conn |> auth(a) |> put(~p"/api/v1/friends/#{b.id}") |> json_response(200)
    assert_schema(response, "FriendsResponse")

    assert %{"friends" => [], "added_you" => [], "requested" => [sent], "requests_waiting" => 0} =
             response["data"]

    assert Map.delete(sent, "requested_at") == player(b)
    assert {:ok, _, _} = DateTime.from_iso8601(sent["requested_at"])
    assert conn |> auth(a) |> put(~p"/api/v1/friends/#{b.id}") |> json_response(200) == response
    response = conn |> auth(b) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert response["data"]["added_you"] == [request(a, b)]
    assert response["data"]["requests_waiting"] == 1
    assert response["data"]["waiting_for_you"] == 1

    response = conn |> auth(b) |> put(~p"/api/v1/friends/#{a.id}") |> json_response(200)
    assert_schema(response, "FriendsResponse")

    assert response ==
             put_in(empty, ["data", "friends"], [Map.put(listed(a), "played_together_at", nil)])

    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200) ==
             put_in(empty, ["data", "friends"], [Map.put(listed(b), "played_together_at", nil)])

    assert conn |> auth(b) |> delete(~p"/api/v1/friends/#{a.id}") |> json_response(200) == empty
    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200) == empty
  end

  test "old clients decode the serialized list while ignoring additive row facts",
       %{conn: conn} do
    a = user_fixture()
    b = user_fixture()
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.add(b.id, a.id)
    {:ok, room} = RoomManager.create_room(b.id, %{seat_holds: %{south: a.id}})
    on_exit(fn -> RoomManager.close_room(room.code) end)
    {:ok, _} = Presence.track(self(), "game:" <> room.code, b.id, %{})

    response = conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    assert [entry] = response["data"]["friends"]
    # A table that has not started reads "At a table · 2 seats open", never "with bots".
    assert entry["table_company"] == "people"
    assert entry["table_open_seats"] == 2
    assert Map.has_key?(entry, "table_hand") and is_nil(entry["table_hand"])
    assert Map.has_key?(entry, "played_together_at") and is_nil(entry["played_together_at"])
    # Old clients read only their known fields, as do the Account e2e journeys.
    assert Map.take(entry, Map.keys(player(b))) == %{player(b) | "presence" => "at_table"}
    assert Enum.map(response["data"]["friends"], & &1["user_id"]) == [b.id]
  end

  test "HTTP ignore hides a request from the recipient only, and un-ignore restores it",
       %{conn: conn} do
    a = user_fixture(%{display_name: "Nora"})
    b = user_fixture(%{display_name: "Vera"})
    sent = conn |> auth(a) |> put(~p"/api/v1/friends/#{b.id}") |> json_response(200)

    hidden = %{
      "data" => %{
        "friends" => [],
        "added_you" => [],
        "requested" => [],
        "requests_waiting" => 0,
        "waiting_for_you" => 0
      }
    }

    for _ <- 1..2 do
      response = conn |> auth(b) |> post(~p"/api/v1/friends/#{a.id}/ignore") |> json_response(200)
      assert_schema(response, "FriendsResponse")
      assert response == hidden
    end

    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200) == sent

    response = conn |> auth(b) |> delete(~p"/api/v1/friends/#{a.id}/ignore") |> json_response(200)
    assert_schema(response, "FriendsResponse")

    assert response == %{
             "data" => %{
               hidden["data"]
               | "added_you" => [request(a, b)],
                 "requests_waiting" => 1,
                 "waiting_for_you" => 1
             }
           }
  end

  test "guest callers are forbidden on every route; missing auth is unauthorized", %{conn: conn} do
    guest = guest_fixture()
    target = user_fixture()

    for {method, path} <- [
          {:get, "/api/v1/friends"},
          {:get, "/api/v1/friends/recent"},
          {:get, "/api/v1/users/search?q=nor"},
          {:put, "/api/v1/friends/#{target.id}"},
          {:delete, "/api/v1/friends/#{target.id}"},
          {:post, "/api/v1/friends/#{target.id}/ignore"},
          {:delete, "/api/v1/friends/#{target.id}/ignore"},
          {:post, "/api/v1/friends/#{target.id}/join"}
        ] do
      assert conn |> auth(guest) |> dispatch(method, path) |> json_response(403) ==
               %{
                 "error" => "ACCOUNT_REQUIRED",
                 "error_code" => "account_required",
                 "error_params" => %{}
               }

      assert conn |> dispatch(method, path) |> json_response(401) == %{
               "errors" => %{"detail" => "Unauthorized"},
               "error_code" => "unauthorized",
               "error_params" => %{}
             }
    end
  end

  test "self and unavailable targets have the contract's status and error code", %{conn: conn} do
    user = user_fixture()
    guest = guest_fixture()

    for {method, suffix} <- [put: "", delete: "", post: "/ignore", delete: "/ignore"] do
      response =
        conn
        |> auth(user)
        |> dispatch(method, "/api/v1/friends/#{user.id}#{suffix}")
        |> json_response(400)

      assert response == %{
               "error" => "CANNOT_FRIEND_SELF",
               "error_code" => "cannot_friend_self",
               "error_params" => %{}
             }

      assert_schema(response, "FriendError")

      for id <- [guest.id, Ecto.UUID.generate(), "invalid"] do
        assert conn
               |> auth(user)
               |> dispatch(method, "/api/v1/friends/#{id}#{suffix}")
               |> json_response(404) ==
                 %{
                   "error" => "USER_NOT_FOUND",
                   "error_code" => "user_not_found",
                   "error_params" => %{}
                 }
      end
    end
  end

  test "search and recent expose discovery entries, and short queries fail", %{conn: conn} do
    user = user_fixture()
    nora = user_fixture(%{display_name: "Nora"})
    {:ok, _} = Friends.add(nora.id, user.id)
    response = conn |> auth(user) |> get(~p"/api/v1/users/search?q=nor") |> json_response(200)
    assert_schema(response, "FriendUsersResponse")
    assert response == %{"data" => %{"users" => [Map.put(player(nora), "relation", "added_you")]}}

    for path <- [
          "/api/v1/users/search",
          "/api/v1/users/search?q=no",
          "/api/v1/users/search?q[]=nor"
        ] do
      assert conn |> auth(user) |> get(path) |> json_response(400) == %{
               "error" => "QUERY_TOO_SHORT",
               "error_code" => "query_too_short",
               "error_params" => %{}
             }
    end

    response = conn |> auth(user) |> get(~p"/api/v1/friends/recent") |> json_response(200)
    assert_schema(response, "FriendUsersResponse")
    assert response == %{"data" => %{"users" => []}}

    played = ~U[2026-10-18 19:30:00Z]

    %PidroServer.Stats.GameStats{}
    |> PidroServer.Stats.GameStats.changeset(%{
      room_code: "TEST",
      completed_at: played,
      player_ids: [user.id, nora.id]
    })
    |> PidroServer.Repo.insert!()

    response = conn |> auth(user) |> get(~p"/api/v1/friends/recent") |> json_response(200)
    assert_schema(response, "FriendUsersResponse")

    assert response == %{
             "data" => %{
               "users" => [
                 Map.merge(player(nora), %{
                   "relation" => "added_you",
                   "played_together_at" => DateTime.to_iso8601(played)
                 })
               ]
             }
           }
  end

  test "search and add limits are independent per user and preserve existing 429s", %{conn: conn} do
    a = user_fixture()
    b = user_fixture()
    with_limit(:user_search, 1, 60_000)
    with_limit(:friend_add, 1, 3_600_000)

    for {method, path} <- [
          {:get, "/api/v1/users/search?q=nor"},
          {:put, "/api/v1/friends/#{b.id}"}
        ] do
      assert conn |> auth(a) |> dispatch(method, path) |> json_response(200)
      denied = conn |> auth(a) |> dispatch(method, path)

      assert [%{"code" => "RATE_LIMITED"}] =
               json_response(denied, 429)["errors"] |> Enum.map(&Map.take(&1, ["code"]))

      assert [_] = get_resp_header(denied, "retry-after")
    end

    assert conn |> auth(b) |> get(~p"/api/v1/users/search?q=nor") |> json_response(200)
    assert conn |> auth(b) |> put(~p"/api/v1/friends/#{a.id}") |> json_response(200)
    assert conn |> auth(a) |> get(~p"/api/v1/friends") |> json_response(200)
    assert conn |> auth(a) |> delete(~p"/api/v1/friends/#{b.id}") |> json_response(200)
  end

  describe "join a friend's table" do
    test "the partner seat when it is free, else an opponent seat", %{conn: conn} do
      nora = user_fixture(%{display_name: "Nora"})
      me = user_fixture()
      other = user_fixture()
      befriend(me, nora)
      befriend(other, nora)
      room = table(nora)

      assert join_as(conn, me, nora) == "partner"
      assert seated(conn, me, nora) == "south"

      assert join_as(conn, other, nora) == "opponent"
      assert seated(conn, other, nora) == "east"
      assert {:ok, %{positions: %{north: _, east: _, south: _}}} = RoomManager.get_room(room.code)
    end

    test "a seat held for someone else is skipped; one held for you is yours", %{conn: conn} do
      nora = user_fixture()
      me = user_fixture()
      invited = user_fixture()
      befriend(me, nora)
      befriend(invited, nora)
      table(nora, %{seat_holds: %{south: invited.id}})

      assert join_as(conn, invited, nora) == "partner"
      assert join_as(conn, me, nora) == "opponent"
      assert seated(conn, me, nora) == "east"
      assert seated(conn, invited, nora) == "south"
    end

    test "a password seat is skipped: this route has no password to give", %{conn: conn} do
      nora = user_fixture()
      me = user_fixture()
      befriend(me, nora)
      room = table(nora)
      {:ok, _} = RoomManager.set_seat(room.code, nora.id, :south, {:open, 0, true})

      assert join_as(conn, me, nora) == "opponent"
      assert seated(conn, me, nora) == "east"
    end

    test "seats you lack the games for are skipped, then there is no seat for you", %{
      conn: conn
    } do
      nora = user_fixture()
      me = user_fixture()
      second = user_fixture()

      for user <- [me, second] do
        befriend(user, nora)
        games(user, 120)
      end

      room = table(nora, %{seat_requirements: %{south: 1000, east: 100}})
      {:ok, _, :west} = RoomManager.join_room(room.code, user_fixture().id, :west)

      assert join_as(conn, me, nora) == "opponent"
      assert seated(conn, me, nora) == "east"

      assert join_as(conn, second, nora) == nil
      response = conn |> auth(second) |> post(join_path(nora)) |> json_response(409)
      assert [%{"code" => "NO_SEAT_FOR_YOU"}] = response["errors"]
      assert response["error_code"] == "no_seat_for_you"
      {:ok, unchanged} = RoomManager.get_room(room.code)
      assert unchanged.positions.south == nil
    end

    test "at a playing table a substitute seat needs no games, as in the room join",
         %{conn: conn} do
      nora = user_fixture()
      me = user_fixture()
      [east, south, west] = for _ <- 1..3, do: user_fixture()
      befriend(me, nora)
      room = table(nora, %{seat_requirements: %{south: 1000}})

      for {user, position} <- [{east, :east}, {south, :south}, {west, :west}] do
        games(user, 1000)
        {:ok, _, ^position} = RoomManager.join_room(room.code, user.id, position)
      end

      PidroServer.RoomFixtures.ready_room(room.code)
      :ok = RoomManager.leave_room(south.id)
      {:ok, opened} = RoomManager.open_seat(room.code, :south, nora.id)
      # A seat a timed-out player lost to a permanent bot keeps their id in positions.
      stale = %{opened | positions: %{opened.positions | south: south.id}}
      assert RoomManager.friend_seat(stale, me.id, nora.id, 0) == {:south, :partner}

      assert join_as(conn, me, nora) == "partner"
      assert seated(conn, me, nora) == "south"
    end

    test "a locked table and a kick keep the room join's own errors", %{conn: conn} do
      nora = user_fixture()
      me = user_fixture()
      befriend(me, nora)
      room = table(nora)
      {:ok, _, :south} = RoomManager.join_room(room.code, me.id, :south)
      {:ok, _} = RoomManager.kick_player(room.code, nora.id, :south)

      assert join_as(conn, me, nora) == nil
      response = conn |> auth(me) |> post(join_path(nora)) |> json_response(403)
      assert [%{"code" => "KICKED"}] = response["errors"]

      {:ok, _} = RoomManager.set_locked(room.code, nora.id, true)
      assert join_as(conn, me, nora) == nil
      response = conn |> auth(me) |> post(join_path(nora)) |> json_response(423)
      assert [%{"code" => "TABLE_LOCKED"}] = response["errors"]
    end

    test "a host blocked either way refuses the join as SEAT_TAKEN", %{conn: conn} do
      for direction <- [:outgoing, :incoming] do
        host = user_fixture()
        nora = user_fixture()
        me = user_fixture()
        befriend(me, nora)
        room = table(host)
        {:ok, _, :east} = RoomManager.join_room(room.code, nora.id, :east)
        {a, b} = if direction == :outgoing, do: {me, host}, else: {host, me}
        {:ok, _} = Blocks.block(a.id, b.id)

        assert join_as(conn, me, nora) == nil
        response = conn |> auth(me) |> post(join_path(nora)) |> json_response(422)
        assert [%{"code" => "SEAT_TAKEN"}] = response["errors"]
      end
    end

    test "a friend not at a table, a non-friend and a blocked friend", %{conn: conn} do
      nora = user_fixture()
      me = user_fixture()
      befriend(me, nora)

      assert join_as(conn, me, nora) == nil
      response = conn |> auth(me) |> post(join_path(nora)) |> json_response(404)
      assert [%{"code" => "ROOM_NOT_FOUND"}] = response["errors"]

      table(nora)
      stranger = user_fixture()
      {:ok, _} = Friends.add(stranger.id, nora.id)

      for user <- [stranger, nora] do
        assert conn |> auth(user) |> post(join_path(nora)) |> json_response(404) ==
                 %{
                   "error" => "USER_NOT_FOUND",
                   "error_code" => "user_not_found",
                   "error_params" => %{}
                 }
      end

      {:ok, _} = Blocks.block(nora.id, me.id)

      assert %{"error" => "USER_NOT_FOUND"} =
               conn |> auth(me) |> post(join_path(nora)) |> json_response(404)
    end
  end

  defp befriend(a, b) do
    {:ok, _} = Friends.add(a.id, b.id)
    {:ok, _} = Friends.add(b.id, a.id)
  end

  defp table(host, config \\ %{}) do
    {:ok, room} = RoomManager.create_room(host.id, config)
    on_exit(fn -> RoomManager.close_room(room.code) end)
    room
  end

  defp games(user, count) do
    {:ok, profile} = PidroServer.Profiles.get_or_create_profile(user.id)
    profile |> Ecto.Changeset.change(games_played: count) |> PidroServer.Repo.update!()
  end

  defp join_path(friend), do: "/api/v1/friends/#{friend.id}/join"

  defp join_as(conn, user, friend) do
    response = conn |> auth(user) |> get(~p"/api/v1/friends") |> json_response(200)
    assert_schema(response, "FriendsResponse")
    Enum.find(response["data"]["friends"], &(&1["user_id"] == friend.id))["join_as"]
  end

  defp seated(conn, user, friend) do
    response = conn |> auth(user) |> post(join_path(friend)) |> json_response(200)
    assert_schema(response, "RoomResponse")
    response["data"]["assigned_position"]
  end

  defp auth(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")

  defp dispatch(conn, :get, path), do: get(conn, path)
  defp dispatch(conn, :put, path), do: put(conn, path)
  defp dispatch(conn, :post, path), do: post(conn, path)
  defp dispatch(conn, :delete, path), do: delete(conn, path)

  defp request(sender, viewer) do
    edge =
      PidroServer.Repo.get_by!(PidroServer.Friends.Friendship,
        user_id: sender.id,
        friend_id: viewer.id
      )

    Map.put(player(sender), "requested_at", DateTime.to_iso8601(edge.inserted_at))
  end

  defp player(user),
    do: %{
      "user_id" => user.id,
      "display_name" => user.display_name || user.username,
      "avatar_url" => nil,
      "level" => 1,
      "prestige" => 0,
      "presence" => "offline"
    }

  defp listed(user), do: Map.put(player(user), "join_as", nil)

  defp assert_schema(response, name),
    do: OpenApiSpex.TestAssertions.assert_schema(response, name, PidroServerWeb.ApiSpec.spec())
end
