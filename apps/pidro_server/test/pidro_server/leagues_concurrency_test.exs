defmodule PidroServer.LeaguesConcurrencyTest do
  use PidroServer.ArchiveCase, async: false
  import PidroServer.AccountsFixtures
  alias PidroServer.{Leagues, Profiles, Stats}
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Leagues.{Membership, Result, Room}

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

  defp save(users) do
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
                   completed_at: ~U[2026-10-29 12:00:00Z],
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
