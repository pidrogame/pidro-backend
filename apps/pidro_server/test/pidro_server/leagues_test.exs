defmodule PidroServer.LeaguesTest do
  use PidroServer.DataCase, async: false
  import PidroServer.AccountsFixtures
  alias PidroServer.{Leagues, Profiles, Stats}
  alias PidroServer.Leagues.{Membership, Player, Room}
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

  test "31st player opens a room Thursday but joins to 40 Saturday" do
    for {at, sizes} <- [{@thursday, [1, 30]}, {~U[2026-11-07 20:00:00Z], [31]}] do
      users = for _ <- 1..31, do: user_fixture()
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

    for start <- [nil, ~U[2099-01-04 19:00:00Z]] do
      Application.put_env(:pidro_server, :leagues_start_at, start)
      users = [user_fixture(), user_fixture()]
      complete(users, @thursday)
      assert Repo.aggregate(Membership, :count) == 0
      assert Repo.aggregate(Room, :count) == 0
      for u <- users, do: assert(Repo.get_by!(GameXp, user_id: u.id).xp > 0)
    end
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
