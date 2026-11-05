defmodule PidroServer.LeaguesConcurrencyTest do
  use PidroServer.ArchiveCase, async: false
  import PidroServer.AccountsFixtures
  alias PidroServer.{Leagues, Profiles, Stats}
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Leagues.{Membership, Player, Result, Room}

  test "independent connections serialize first games, capacity and competing closes" do
    users = for _ <- 1..33, do: user_fixture()
    [a, b, c, d | _] = users
    race([fn -> save([a, b]) end, fn -> save([c, d]) end])
    assert Repo.aggregate(Room, :count) == 1

    for pair <- users |> Enum.take(29) |> Enum.chunk_every(2, 1, :discard), do: save(pair)
    assert Repo.aggregate(Membership, :count) == 29
    race([fn -> save([a, Enum.at(users, 29)]) end, fn -> save([a, Enum.at(users, 30)]) end])

    assert Repo.all(from m in Membership, group_by: m.room_id, select: count(m.id)) |> Enum.sort() ==
             [1, 30]

    {_, closes} = Leagues.week(~U[2026-10-29 12:00:00Z])

    outcomes =
      race([
        fn -> Leagues.close(closes, DateTime.add(closes, 120)) end,
        fn -> Leagues.close(closes, DateTime.add(closes, 120)) end
      ])

    assert Enum.count(outcomes, &(&1 == {:ok, 0})) == 1
    assert Repo.aggregate(Result, :count) == 31
    assert Repo.aggregate(from(r in Result, where: r.move == "up"), :count) == 10
  end

  test "concurrent arrivals compete for the last seat in their friend's older room" do
    [friend | _] = users = for _ <- 1..29, do: user_fixture()
    for pair <- Enum.chunk_every(users, 2, 1, :discard), do: save(pair)
    preferred = Repo.get_by!(Membership, user_id: friend.id).room_id
    {starts, closes} = Leagues.week(~U[2026-10-29 12:00:00Z])
    normal = Repo.insert!(%Room{league: "deuce", starts_at: starts, closes_at: closes})
    [a, b] = newcomers = for _ <- 1..2, do: user_fixture()

    for user <- newcomers,
        {u, v} <- [{user, friend}, {friend, user}],
        do: Repo.insert!(%PidroServer.Friends.Friendship{user_id: u.id, friend_id: v.id})

    guest_a = guest_fixture()
    guest_b = guest_fixture()
    race([fn -> save([a, guest_a]) end, fn -> save([b, guest_b]) end])

    assert Repo.aggregate(from(m in Membership, where: m.room_id == ^preferred), :count) == 30
    assert Repo.aggregate(from(m in Membership, where: m.room_id == ^normal.id), :count) == 1

    assert MapSet.new(newcomers, &Repo.get_by!(Membership, user_id: &1.id).room_id) ==
             MapSet.new([preferred, normal.id])
  end

  test "close races new-week credit and grace hiding without stale rooms or resurrection" do
    for action <- [:credit, :hide] do
      a = user_fixture()
      b = user_fixture()
      close = if action == :credit, do: ~U[2026-11-01 19:00:00Z], else: ~U[2026-11-08 19:00:00Z]

      room =
        Repo.insert!(%Room{
          league: "ten",
          starts_at: DateTime.add(close, -604_800),
          closes_at: close
        })

      for {user, points} <- [{a, 100}, {b, 10}] do
        Repo.insert!(%Player{user_id: user.id, league: "ten"})

        Repo.insert!(%Membership{
          room_id: room.id,
          user_id: user.id,
          closes_at: close,
          points: points,
          points_at: DateTime.utc_now(),
          placed_at: DateTime.utc_now()
        })
      end

      at = DateTime.add(close, 30)
      if action == :hide, do: save([a, b], at)

      race([
        fn -> Leagues.close(close, DateTime.add(close, 120)) end,
        fn -> if action == :credit, do: save([a, b], at), else: Leagues.hidden(a, true, at) end
      ])

      assert Repo.get_by!(Result, user_id: a.id, week_closes_at: close).move == "up"
      next = DateTime.add(close, 604_800)

      if action == :credit do
        member = Repo.get_by!(Membership, user_id: a.id, closes_at: next)
        assert Repo.get!(Room, member.room_id).league == "jack"
      else
        refute Repo.get_by(Membership, user_id: a.id, closes_at: next)
        assert Leagues.player(a.id).hidden
      end
    end
  end

  defp race(funs) do
    parent = self()

    tasks =
      Enum.map(funs, fn fun ->
        Task.async(fn ->
          Repo.checkout(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), backend})
            receive do: (:go -> fun.())
          end)
        end)
      end)

    workers =
      for _ <- tasks do
        assert_receive {:ready, pid, backend}, 5000
        {pid, backend}
      end

    assert workers |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == length(funs)
    for {pid, _} <- workers, do: send(pid, :go)
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  defp save(users, at \\ ~U[2026-10-29 12:00:00Z]) do
    positions = [:north, :east, :south, :west]

    seats =
      positions
      |> Enum.with_index()
      |> Map.new(fn {pos, i} ->
        {pos,
         if(user = Enum.at(users, i),
           do: Seat.new_human(pos, user.id),
           else: Seat.new_bot(pos, nil)
         )}
      end)

    results = Stats.build_player_results(seats, :north_south, [])

    assert {:ok, _} =
             Repo.transaction(fn ->
               {:ok, game} =
                 Stats.save_game_result(%{
                   room_code: Ecto.UUID.generate(),
                   completed_at: at,
                   player_ids: Map.keys(results),
                   player_results: results,
                   winner: :north_south,
                   final_scores: %{north_south: 62, east_west: 40}
                 })

               Profiles.apply_completed_game(results, :north_south, game.final_scores, %{},
                 game: game
               )
             end)
  end
end
