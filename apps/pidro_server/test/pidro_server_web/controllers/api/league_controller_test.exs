defmodule PidroServerWeb.API.LeagueControllerTest do
  use PidroServerWeb.ConnCase, async: false
  import PidroServer.AccountsFixtures
  import Ecto.Query
  alias PidroServer.{Leagues, Repo, Stats}
  alias PidroServer.Accounts.Token
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Leagues.{Membership, Player, Result, Room}

  test "raw statuses, every route, validation and authentication", %{conn: conn} do
    user = user_fixture()
    response = conn |> auth(user) |> get("/api/v1/league") |> json_response(200)
    assert response["status"] == "not_placed"
    assert response["league"] == "deuce"
    assert_schema(response, "LeagueResponse")
    refute Map.has_key?(response, "data")

    for _ <- 1..2 do
      assert conn |> auth(user) |> post("/api/v1/league/intro_seen") |> response(204) == ""
    end

    assert (conn |> auth(user) |> get("/api/v1/league") |> json_response(200))["intro_seen"]

    for {hidden, status} <- [{true, "opted_out"}, {false, "not_placed"}] do
      data =
        conn
        |> auth(user)
        |> put("/api/v1/league/hidden", %{hidden: hidden})
        |> json_response(200)

      assert data["status"] == status
      assert_schema(data, "LeagueResponse")
    end

    assert conn
           |> auth(user)
           |> put("/api/v1/league/hidden", %{hidden: "bad"})
           |> json_response(422)

    assert conn |> auth(user) |> put("/api/v1/league/hidden", %{}) |> json_response(422)

    for {hidden, status} <- [
          {"true", "opted_out"},
          {"false", "not_placed"},
          {"1", "opted_out"},
          {"0", "not_placed"}
        ] do
      assert (conn
              |> auth(user)
              |> put("/api/v1/league/hidden", %{hidden: hidden})
              |> json_response(200))["status"] == status
    end

    assert conn
           |> auth(user)
           |> post("/api/v1/league/results/not-a-uuid/seen")
           |> json_response(404)

    guest = guest_fixture()
    data = conn |> auth(guest) |> get("/api/v1/league") |> json_response(200)
    assert data["status"] == "guest"
    assert_schema(data, "LeagueResponse")

    for {method, path, body} <- [
          {:get, "/api/v1/league", %{}},
          {:post, "/api/v1/league/intro_seen", %{}},
          {:post, "/api/v1/league/results/#{Ecto.UUID.generate()}/seen", %{}},
          {:put, "/api/v1/league/hidden", %{hidden: true}}
        ] do
      assert conn
             |> Phoenix.ConnTest.dispatch(@endpoint, method, path, body)
             |> json_response(401)

      if method != :get do
        assert (conn
                |> auth(guest)
                |> Phoenix.ConnTest.dispatch(@endpoint, method, path, body)
                |> json_response(403))["error_code"] == "account_required"
      end
    end
  end

  test "real save counts humans including a departed human, not bots; preserves solo XP", %{
    conn: conn
  } do
    for kind <- [:solo, :two, :four, :guest, :departed] do
      users = for _ <- 1..4, do: user_fixture()
      [a, b, _, _] = users

      seats =
        [:north, :east, :south, :west]
        |> Enum.zip(users)
        |> Map.new(fn {pos, u} -> {pos, Seat.new_human(pos, u.id)} end)

      seats =
        if kind == :four,
          do: seats,
          else:
            seats
            |> Map.put(:south, Seat.new_bot(:south, nil))
            |> Map.put(:west, Seat.new_bot(:west, nil))

      seats =
        case kind do
          :solo ->
            Map.put(seats, :east, Seat.new_bot(:east, nil))

          :guest ->
            Map.put(seats, :east, Seat.new_human(:east, guest_fixture().id))

          :departed ->
            Map.put(seats, :east, %{
              Seat.new_bot(:east, nil)
              | reserved_for: b.id,
                status: :bot_substitute
            })

          _ ->
            seats
        end

      room = %{code: Ecto.UUID.generate(), seats: seats, created_at: DateTime.utc_now()}

      assert {:ok, _} =
               Stats.save_completed_game(room, :north_south, %{north_south: 62, east_west: 40})

      assert :ok =
               Stats.save_completed_game(room, :north_south, %{north_south: 62, east_west: 40})

      data = conn |> auth(a) |> get("/api/v1/league") |> json_response(200)
      assert data["status"] == if(kind == :solo, do: "not_placed", else: "placed")
      assert_schema(data, "LeagueResponse")
      assert Repo.get_by!(PidroServer.Profiles.GameXp, user_id: a.id).xp > 0
      if kind == :departed, do: assert(Repo.get_by(Membership, user_id: b.id))
    end
  end

  test "off gate stops real save placement, close and HTTP league data", %{conn: conn} do
    original = Leagues.start_at()
    on_exit(fn -> Application.put_env(:pidro_server, :leagues_start_at, original) end)
    Application.delete_env(:pidro_server, :leagues_start_at)
    a = user_fixture()
    b = user_fixture()

    room = %{
      code: Ecto.UUID.generate(),
      created_at: DateTime.utc_now(),
      seats: %{
        north: Seat.new_human(:north, a.id),
        east: Seat.new_human(:east, b.id),
        south: Seat.new_bot(:south, nil),
        west: Seat.new_bot(:west, nil)
      }
    }

    assert {:ok, _} =
             Stats.save_completed_game(room, :north_south, %{north_south: 62, east_west: 40})

    assert Repo.aggregate(Membership, :count) == 0
    assert {:ok, 0} = Leagues.close_due()
    data = conn |> auth(a) |> get("/api/v1/league") |> json_response(200)
    assert data["status"] == "off"
    assert data["league"] == nil
    assert data["week"] == nil
    assert_schema(data, "LeagueResponse")
  end

  test "ordered results are owned and acknowledgments idempotent", %{conn: conn} do
    a = user_fixture()
    b = user_fixture()
    {starts, _} = Leagues.week(DateTime.utc_now())
    previous = DateTime.add(starts, -604_800)
    room = Repo.insert!(%Room{league: "ten", starts_at: previous, closes_at: starts})
    now = DateTime.utc_now()

    Repo.insert!(%Membership{
      room_id: room.id,
      user_id: a.id,
      closes_at: starts,
      points: 100,
      points_at: now,
      placed_at: now
    })

    Leagues.close(starts, DateTime.add(starts, 120))
    result = Repo.one!(from r in Result, where: r.user_id == ^a.id)
    data = conn |> auth(a) |> get("/api/v1/league") |> json_response(200)
    assert_schema(data, "LeagueResponse")
    assert data["pending_result"]["id"] == result.id
    assert is_boolean(data["pending_result"]["ribbon"]["star_possible"])

    assert conn
           |> auth(b)
           |> post("/api/v1/league/results/#{result.id}/seen")
           |> json_response(404)

    for _ <- 1..2,
        do:
          assert(
            conn |> auth(a) |> post("/api/v1/league/results/#{result.id}/seen") |> response(204) ==
              ""
          )

    assert (conn |> auth(a) |> get("/api/v1/league") |> json_response(200))["pending_result"] ==
             nil
  end

  test "friends compare points across leagues; standings mark only visible mutual friends", %{
    conn: conn
  } do
    a = user_fixture()
    b = user_fixture()
    c = user_fixture()
    outsider = user_fixture()
    {starts, closes} = Leagues.week(DateTime.utc_now())
    now = DateTime.utc_now()
    room = Repo.insert!(%Room{league: "ace", starts_at: starts, closes_at: closes})
    lower = Repo.insert!(%Room{league: "deuce", starts_at: starts, closes_at: closes})

    for {u, points, placed} <- [
          {a, 20, room},
          {b, 50, room},
          {outsider, 100, room},
          {c, 200, lower}
        ] do
      Repo.insert!(%Player{user_id: u.id, league: placed.league})

      Repo.insert!(%Membership{
        room_id: placed.id,
        user_id: u.id,
        closes_at: closes,
        points: points,
        points_at: now,
        placed_at: now
      })
    end

    for {u, v} <- [{a, b}, {b, a}, {a, c}, {c, a}, {outsider, a}],
        do: Repo.insert!(%PidroServer.Friends.Friendship{user_id: u.id, friend_id: v.id})

    data = conn |> auth(a) |> get("/api/v1/league") |> json_response(200)

    assert [
             %{"user_id" => lower_id, "league" => "deuce", "points" => 200, "place" => 1},
             %{
               "user_id" => id,
               "league" => "ace",
               "points" => 50,
               "place" => 2,
               "avatar" => %{"url" => nil}
             }
           ] = data["friends"]

    assert lower_id == c.id
    assert id == b.id

    assert Enum.map(data["room"]["standings"], &{&1["user_id"], &1["friend"]}) ==
             [{outsider.id, false}, {b.id, true}, {a.id, false}]

    assert_schema(data, "LeagueResponse")

    Repo.get!(Player, b.id) |> Ecto.Changeset.change(hidden: true) |> Repo.update!()
    hidden = conn |> auth(a) |> get("/api/v1/league") |> json_response(200)
    assert Enum.map(hidden["friends"], & &1["user_id"]) == [c.id]
    refute Enum.find(hidden["room"]["standings"], &(&1["user_id"] == b.id))["friend"]
    Repo.get!(Player, b.id) |> Ecto.Changeset.change(hidden: false) |> Repo.update!()

    for {u, v} <- [{a, b}, {b, a}] do
      Repo.insert!(%PidroServer.Blocks.Block{user_id: u.id, blocked_id: v.id})
      blocked = conn |> auth(a) |> get("/api/v1/league") |> json_response(200)
      assert Enum.map(blocked["friends"], & &1["user_id"]) == [c.id]
      refute Enum.find(blocked["room"]["standings"], &(&1["user_id"] == b.id))["friend"]
      Repo.delete_all(PidroServer.Blocks.Block)
    end
  end

  defp auth(conn, user) do
    put_req_header(conn, "authorization", "Bearer " <> Token.generate(user))
  end

  defp assert_schema(response, name),
    do: OpenApiSpex.TestAssertions.assert_schema(response, name, PidroServerWeb.ApiSpec.spec())
end
