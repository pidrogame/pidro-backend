defmodule PidroServer.LeaguesTest do
  use PidroServer.DataCase, async: false
  import PidroServer.AccountsFixtures
  alias PidroServer.{Leagues, Profiles, Stats}
  alias PidroServer.Leagues.{Membership, Player, Result, Room}
  alias PidroServer.Profiles.GameXp

  @thursday ~U[2026-10-29 12:00:00Z]
  @close ~U[2026-11-01 19:00:00Z]

  test "Sunday is half-open, including the month boundary" do
    assert Leagues.week(~U[2026-11-01 18:59:59Z]) == {~U[2026-10-25 19:00:00Z], @close}

    for at <- [@close, ~U[2026-11-01 19:00:01Z]] do
      assert Leagues.week(at) == {@close, ~U[2026-11-08 19:00:00Z]}
    end

    assert Leagues.week(~U[2026-10-31 23:59:59Z]) == Leagues.week(@thursday)
  end

  test "bands at every requested room size" do
    expected = %{
      "deuce" => [{0, 0}, {1, 0}, {1, 0}, {4, 0}, {10, 0}, {13, 0}],
      "ten" => [{0, 0}, {1, 0}, {1, 1}, {3, 2}, {7, 5}, {9, 7}],
      "jack" => [{0, 0}, {1, 0}, {1, 1}, {2, 2}, {5, 5}, {7, 7}],
      "ace" => [{0, 0}, {1, 0}, {1, 1}, {1, 2}, {3, 5}, {4, 7}],
      "pidro" => [{0, 0}, {0, 1}, {0, 1}, {0, 3}, {0, 8}, {0, 11}]
    }

    for {league, bands} <- expected do
      assert Enum.map([1, 2, 4, 12, 30, 40], &Leagues.bands(league, &1)) == bands
    end
  end

  test "solo XP stays paid, guests count but cannot place, two and four humans place" do
    solo = user_fixture()
    complete([solo], @thursday)
    assert Repo.get_by!(GameXp, user_id: solo.id).xp > 0
    refute Repo.get_by(Membership, user_id: solo.id)

    guest = guest_fixture()
    registered = user_fixture()
    complete([guest, registered], @thursday)
    refute Repo.get_by(Membership, user_id: guest.id)
    assert Repo.get_by!(Membership, user_id: registered.id).points > 0

    for n <- [2, 4] do
      users = for _ <- 1..n, do: user_fixture()
      complete(users, @thursday)

      for user <- users do
        assert Repo.get_by!(Membership, user_id: user.id).points ==
                 Repo.get_by!(GameXp, user_id: user.id).xp
      end
    end
  end

  test "31st player opens Thursday, Saturday extends to 40 but never 41" do
    for {at, count, sizes} <- [{@thursday, 31, [1, 30]}, {~U[2026-11-07 20:00:00Z], 41, [1, 40]}] do
      users = for _ <- 1..count, do: user_fixture()
      for pair <- Enum.chunk_every(users, 2, 1, :discard), do: complete(pair, at)
      {_, closes} = Leagues.week(at)

      assert Repo.all(
               from m in Membership,
                 where: m.closes_at == ^closes,
                 group_by: m.room_id,
                 select: count(m.id)
             )
             |> Enum.sort() == sizes
    end
  end

  test "off and future gates do no league SQL but still pay XP" do
    original = Leagues.start_at()
    on_exit(fn -> Application.put_env(:pidro_server, :leagues_start_at, original) end)
    handler = make_ref()
    on_exit(fn -> :telemetry.detach(handler) end)

    for start <- [nil, ~U[2099-01-04 19:00:00Z]] do
      Application.put_env(:pidro_server, :leagues_start_at, start)
      users = [user_fixture(), user_fixture()]

      :telemetry.attach(
        handler,
        [:pidro_server, :repo, :query],
        &__MODULE__.capture_league_query/4,
        self()
      )

      complete(users, @thursday)
      :telemetry.detach(handler)
      refute_receive {:league_query, _}
      assert Repo.aggregate(Membership, :count) == 0
      assert Repo.aggregate(Room, :count) == 0
      for u <- users, do: assert(Repo.get_by!(GameXp, user_id: u.id).xp > 0)
    end
  end

  def capture_league_query(_event, _measurements, %{query: query}, test) do
    if String.contains?(query, ["league_", "pg_advisory_xact_lock"]),
      do: send(test, {:league_query, query})
  end

  test "hidden and Classic players are not seeded into a higher league" do
    hidden = user_fixture()
    Repo.insert!(%Player{user_id: hidden.id, hidden: true})
    classic = user_fixture()
    {:ok, p} = Profiles.get_or_create_profile(classic.id)
    Repo.update!(Ecto.Changeset.change(p, heritage_flags: %{played_pidro_one: true}))
    complete([hidden, classic], @thursday)
    refute Repo.get_by(Membership, user_id: hidden.id)
    member = Repo.get_by!(Membership, user_id: classic.id)
    assert Repo.get!(Room, member.room_id).league == "deuce"
  end

  test "full close scales movement, skips absent players and reruns without changes" do
    skipped = user_fixture()
    Repo.insert!(%Player{user_id: skipped.id, league: "ace"})
    for league <- ["ten", "deuce", "pidro"], do: seed_room(league, 30, @thursday)
    assert {:ok, n} = Leagues.close(@close, DateTime.add(@close, 120))
    assert n > 0
    results = Repo.all(from r in Result, order_by: r.place)
    ten = Enum.filter(results, &(&1.old_league == "ten"))
    assert Enum.map(Enum.take(ten, 7), & &1.new_league) == List.duplicate("jack", 7)
    assert Enum.map(Enum.take(ten, -5), & &1.new_league) == List.duplicate("deuce", 5)
    refute Enum.any?(results, &(&1.old_league == "deuce" and &1.move == "down"))
    assert Enum.count(results, &(&1.old_league == "pidro" and &1.move == "down")) == 8
    assert Leagues.player(skipped.id).league == "ace"
    assert {:ok, 0} = Leagues.close(@close, DateTime.add(@close, 180))
    assert Repo.all(from r in Result, order_by: r.place) == results
  end

  test "hide locks in demotion or staying and cannot farm another result by unhiding" do
    Leagues.close(elem(Leagues.week(@thursday), 0), @thursday)
    {_room, users} = seed_room("ten", 30, @thursday)

    for {index, tier} <- [{29, "deuce"}, {14, "ten"}] do
      user = Enum.at(users, index)
      assert {:ok, _} = Leagues.hidden(user, true, @thursday)
      assert Leagues.player(user.id).league == tier
      result = Repo.get_by!(Result, user_id: user.id)
      assert result.seen_at
      refute Repo.get_by(Membership, user_id: user.id)
      assert {:ok, _} = Leagues.hidden(user, false, @thursday)
      complete([user, user_fixture()], @thursday)
      refute Repo.get_by(Membership, user_id: user.id)
      assert Repo.get_by!(Result, user_id: user.id) == result
    end
  end

  test "Sunday grace transfers points unchanged, but never resurrects a hidden membership" do
    {_room, users} = seed_room("ten", 30, @thursday)
    [up, hiding | _] = users
    new_at = DateTime.add(@close, 30)
    complete([up, hiding], new_at)
    before = Repo.get_by!(Membership, user_id: up.id, closes_at: DateTime.add(@close, 604_800))
    assert {:ok, _} = Leagues.hidden(hiding, true, new_at)
    assert Repo.aggregate(Result, :count) == 0
    assert {:ok, _} = Leagues.close(@close, DateTime.add(@close, 120))
    after_member = Repo.get!(Membership, before.id)
    assert after_member.points == before.points
    assert after_member.points_at == before.points_at
    assert after_member.placed_at == before.placed_at
    assert Repo.get!(Room, after_member.room_id).league == "jack"
    assert Repo.get_by!(Result, user_id: hiding.id).move == "up"
    refute Repo.get_by(Membership, user_id: hiding.id, closes_at: before.closes_at)
  end

  test "late games only change existing closed memberships, never frozen results" do
    {_room, [played | _]} = seed_room("ten", 2, @thursday)
    Leagues.close(@close, DateTime.add(@close, 120))
    result = Repo.get_by!(Result, user_id: played.id)
    old_points = Repo.get_by!(Membership, user_id: played.id).points
    newcomer = user_fixture()
    complete([played, newcomer], @thursday)
    assert Repo.get_by!(Membership, user_id: played.id).points > old_points
    assert Repo.get_by!(Result, user_id: played.id) == result
    refute Repo.get_by(Membership, user_id: newcomer.id)
  end

  test "grace transfers fill the destination to 30, then create another room" do
    {_old, [a, b | _]} = seed_room("ten", 8, @thursday)
    at = DateTime.add(@close, 30)
    {_destination, _users} = seed_room("jack", 29, at)
    complete([a, b], at)
    Leagues.close(@close, DateTime.add(@close, 120))
    next = DateTime.add(@close, 604_800)

    sizes =
      Repo.all(
        from m in Membership,
          join: r in Room,
          on: m.room_id == r.id,
          where: r.closes_at == ^next and r.league == "jack",
          group_by: r.id,
          select: count(m.id)
      )

    assert Enum.sort(sizes) == [1, 30]
  end

  test "an unseen result cannot promise a star after a later skipped close" do
    {_room, [user]} = seed_room("ten", 1, @thursday)
    Leagues.close(@close, DateTime.add(@close, 120))
    assert Leagues.show(user, ~U[2026-11-04 12:00:00Z]).pending_result.ribbon["star_possible"]
    refute Leagues.show(user, ~U[2026-11-09 12:00:00Z]).pending_result.ribbon["star_possible"]
    complete([user, user_fixture()], ~U[2026-11-05 12:00:00Z])
    next = DateTime.add(@close, 604_800)
    Leagues.close(next, DateTime.add(next, 120))
    assert Leagues.show(user, ~U[2026-11-09 12:00:00Z]).pending_result.ribbon["star_possible"]
  end

  test "shared sandbox processes place together without duplicating the first room" do
    users = for _ <- 1..4, do: user_fixture()

    users
    |> Enum.chunk_every(2)
    |> Enum.map(fn pair -> Task.async(fn -> complete(pair, @thursday) end) end)
    |> Enum.each(&Task.await/1)

    assert Repo.aggregate(Room, :count) == 1
    assert Repo.aggregate(Membership, :count) == 4
  end

  test "a failed result rolls back the claim, earlier results, movement and room closure" do
    {room, users} = seed_room("ten", 4, @thursday)
    Repo.query!("ALTER TABLE league_results ADD CONSTRAINT fail_second CHECK (points <> 998)")
    assert_raise Ecto.ConstraintError, fn -> Leagues.close(@close, DateTime.add(@close, 120)) end
    refute Repo.get!(Room, room.id).closed_at
    assert Repo.aggregate(Result, :count) == 0
    assert Repo.aggregate("league_weeks", :count) == 0
    for user <- users, do: assert(Leagues.player(user.id).league == "ten")
    Repo.query!("ALTER TABLE league_results DROP CONSTRAINT fail_second")
    assert {:ok, n} = Leagues.close(@close, DateTime.add(@close, 120))
    assert n > 0
    assert Repo.aggregate(Result, :count) == 4
  end

  defp seed_room(league, n, at) do
    {starts, closes} = Leagues.week(at)
    at = DateTime.from_unix!(DateTime.to_unix(at, :microsecond), :microsecond)
    room = Repo.insert!(%Room{league: league, starts_at: starts, closes_at: closes})

    users =
      for i <- 1..n do
        user = user_fixture()
        Repo.insert!(%Player{user_id: user.id, league: league})

        Repo.insert!(%Membership{
          room_id: room.id,
          user_id: user.id,
          closes_at: closes,
          points: 1000 - i,
          points_at: at,
          placed_at: at
        })

        user
      end

    {room, users}
  end

  defp complete(users, at) do
    results =
      users
      |> Enum.with_index()
      |> Map.new(fn {user, i} ->
        {user.id,
         %{
           participation: :played,
           result: if(rem(i, 2) == 0, do: :win, else: :loss),
           team: if(rem(i, 2) == 0, do: :north_south, else: :east_west)
         }}
      end)

    Repo.transaction(fn ->
      {:ok, game} =
        Stats.save_game_result(%{
          room_code: Ecto.UUID.generate(),
          completed_at: at,
          winner: :north_south,
          final_scores: %{north_south: 62, east_west: 40},
          player_ids: Map.keys(results),
          player_results: results
        })

      Profiles.apply_completed_game(results, :north_south, game.final_scores, %{}, game: game)
    end)
  end
end
