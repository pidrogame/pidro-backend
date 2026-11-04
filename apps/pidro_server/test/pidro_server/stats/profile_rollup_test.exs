defmodule PidroServer.Stats.ProfileRollupTest do
  @moduledoc """
  Integration tests for the profile rollup hook in Stats.save_completed_game/4.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.RoomManager
  alias PidroServer.Profiles
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Profiles.{Achievement, GameXp, PlayerProfile}
  alias PidroServer.Progression
  alias PidroServer.Rating
  alias PidroServer.Stats
  alias PidroServer.Stats.{AbandonmentEvent, GameStats}

  @delta 1.0e-9
  @base ~U[2026-06-07 12:00:00Z]

  test "historical completion credits the same games to profiles, XP periods and league weeks" do
    user = AccountsFixtures.user_fixture()
    guest = AccountsFixtures.guest_fixture()

    for {at, score} <- [{~U[2026-10-31 18:00:00Z], 62}, {~U[2026-11-01 19:00:00Z], 70}] do
      room = %{
        code: Ecto.UUID.generate(),
        created_at: DateTime.add(at, -300),
        seats: %{
          north: Seat.new_human(:north, user.id),
          east: Seat.new_human(:east, guest.id),
          south: Seat.new_bot(:south, nil),
          west: Seat.new_bot(:west, nil)
        }
      }

      assert {:ok, _} =
               Stats.save_completed_game(
                 room,
                 :north_south,
                 %{north_south: score, east_west: 40},
                 nil,
                 completed_at: at
               )

      game = Repo.get_by!(GameStats, room_code: room.code)
      assert game.completed_at == at
      assert game.duration_seconds == 300
      assert Repo.get_by!(GameXp, game_stats_id: game.id, user_id: user.id).earned_at == at
    end

    profile = Repo.get_by!(PlayerProfile, user_id: user.id)
    assert profile.games_played == 2
    assert profile.veteran_xp == 232

    assert Profiles.xp_periods(user.id, ~U[2026-11-02 12:00:00Z]) == %{
             this_week: 0,
             this_month: 120
           }

    assert Repo.get_by!(PidroServer.Leagues.Membership,
             user_id: user.id,
             closes_at: ~U[2026-11-01 19:00:00Z]
           ).points == 112

    assert Repo.get_by!(PidroServer.Leagues.Membership,
             user_id: user.id,
             closes_at: ~U[2026-11-08 19:00:00Z]
           ).points == 120
  end

  test "Louisiana persists and skips live, full and incremental ratings for four real users" do
    ids = for _ <- 1..4, do: player_id()
    [n, e, s, w] = ids

    results =
      Map.new(Enum.zip(ids, [:north, :east, :south, :west]), fn {id, position} ->
        won = position in [:north, :south]

        {id,
         %{
           participation: :played,
           result: if(won, do: :win, else: :loss),
           team: if(won, do: :north_south, else: :east_west),
           position: position
         }}
      end)

    assert {:rated, _} = Profiles.rate_game(results, :north_south, %{})
    assert :unrated = Profiles.rate_game(results, :north_south, %{}, :louisiana)

    # A prior Finnish row gives non-default ratings and a cursor. Skipping a
    # Louisiana row must preserve these, not reset them to defaults.
    for id <- ids, do: Profiles.get_or_create_profile(id)

    {:ok, finnish} =
      Stats.save_game_result(%{
        room_code: "FINN",
        winner: :north_south,
        completed_at: @base,
        player_ids: ids,
        player_results: results,
        final_scores: %{north_south: 62, east_west: 40}
      })

    assert finnish.rule_set == "finnish"
    assert {:ok, %{games: 1}} = Profiles.rerate_all()

    priors =
      Map.new(ids, fn id ->
        p = Repo.get_by!(PlayerProfile, user_id: id)
        {id, {p.rating_mu, p.rating_sigma}}
      end)

    refute priors[n] == Rating.default()

    {:ok, room} = RoomManager.create_room(n, %{rule_set: :louisiana})
    for id <- [e, s, w], do: {:ok, _, _} = RoomManager.join_room(room.code, id)
    {:ok, room} = RoomManager.get_room(room.code)

    assert {:ok, _} =
             Stats.save_completed_game(room, :north_south, %{north_south: 62, east_west: 40})

    saved = Repo.get_by!(GameStats, room_code: room.code)
    assert saved.rule_set == "louisiana"
    assert map_size(saved.player_results) == 4

    for {rerate, expected} <- [
          {fn -> {:ok, %{games: 0}} end, 0},
          {&Profiles.rerate_incremental/0, 0},
          {&Profiles.rerate_all/0, 1}
        ] do
      assert {:ok, %{games: ^expected}} = rerate.()

      for id <- ids do
        p = Repo.get_by!(PlayerProfile, user_id: id)
        {mu, sigma} = priors[id]
        assert p.rating_mu == mu
        assert p.rating_sigma == sigma
        assert p.rating_games_count == 1
        assert p.games_played == 1
        assert p.wins == if(id in [n, s], do: 1, else: 0)
        assert p.losses == if(id in [e, w], do: 1, else: 0)
        won = id in [n, s]
        assert p.veteran_xp == Progression.xp_for_game(if(won, do: 62, else: 40), won)
      end
    end
  end

  setup do
    case GenServer.whereis(RoomManager) do
      nil -> start_supervised!(RoomManager)
      _pid -> :ok
    end

    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)

    case GenServer.whereis(PidroServer.Games.Bots.BotSupervisor) do
      nil -> start_supervised!(PidroServer.Games.Bots.BotSupervisor)
      _pid -> :ok
    end

    :ok
  end

  test "completing a game inserts game_stats and bumps each participant's profile" do
    user1 = player_id()
    user2 = player_id()
    user3 = player_id()
    user4 = player_id()

    {:ok, room} = RoomManager.create_room(user1, %{name: "Rollup"})
    {:ok, _, _} = RoomManager.join_room(room.code, user2)
    {:ok, _, _} = RoomManager.join_room(room.code, user3)
    {:ok, _, _} = RoomManager.join_room(room.code, user4)
    # Only a game being played can end.
    PidroServer.RoomFixtures.ready_room(room.code)

    game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
    send(GenServer.whereis(RoomManager), game_over)

    saved_game = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)
    assert saved_game.winner == "north_south"

    # Every human participant has a profile with one game played.
    for user_id <- saved_game.player_ids do
      assert {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.games_played == 1
    end

    # Total played count matches the number of recorded human seats.
    assert Repo.aggregate(PlayerProfile, :count) == length(saved_game.player_ids)
  end

  test "re-running completion does not double-increment profiles" do
    user1 = player_id()
    user2 = player_id()
    user3 = player_id()
    user4 = player_id()

    {:ok, room} = RoomManager.create_room(user1, %{name: "Idempotent"})
    {:ok, _, _} = RoomManager.join_room(room.code, user2)
    {:ok, _, _} = RoomManager.join_room(room.code, user3)
    {:ok, _, _} = RoomManager.join_room(room.code, user4)
    # Only a game being played can end.
    PidroServer.RoomFixtures.ready_room(room.code)

    game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
    send(GenServer.whereis(RoomManager), game_over)
    send(GenServer.whereis(RoomManager), game_over)

    saved_game = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)

    # Give the second message time to be processed.
    _ = :sys.get_state(GenServer.whereis(RoomManager))

    assert Repo.aggregate(GameStats, :count) == 1

    for user_id <- saved_game.player_ids do
      assert {:ok, %{games_played: 1}} = Profiles.get_or_create_profile(user_id)
    end
  end

  test "a player who deletes their account mid-game gets no profile row when it finishes" do
    [n, e, s, w] = for _ <- 1..4, do: player_id()

    {:ok, room} = RoomManager.create_room(n, %{name: "Deleted"})
    {:ok, _, _} = RoomManager.join_room(room.code, e)
    {:ok, _, _} = RoomManager.join_room(room.code, s)
    {:ok, _, _} = RoomManager.join_room(room.code, w)
    PidroServer.RoomFixtures.ready_room(room.code)

    {:ok, _deleted} = Auth.delete_user(Repo.get!(User, e))

    game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
    send(GenServer.whereis(RoomManager), game_over)

    saved = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)

    # The bare id stays in game_stats and abandonment_events (KD9) ...
    assert e in saved.player_ids
    assert [%AbandonmentEvent{}] = Repo.all(from a in AbandonmentEvent, where: a.user_id == ^e)

    # ... but nothing else is written for it.
    assert is_nil(Repo.get_by(PlayerProfile, user_id: e))
    assert is_nil(Repo.get_by(Achievement, user_id: e))

    # The other three are rated as a full four-player game.
    assert {:rated, ratings} = Profiles.rate_game(saved.player_results, :north_south, %{})

    for id <- [n, s, w] do
      p = Repo.get_by!(PlayerProfile, user_id: id)
      {mu, sigma} = Map.fetch!(ratings, id)
      assert p.games_played == 1
      assert p.rating_games_count == 1
      assert_in_delta p.rating_mu, mu, @delta
      assert_in_delta p.rating_sigma, sigma, @delta
    end
  end

  test "a forced stats-insert failure leaves no profile changes (rollback)" do
    user_id = player_id()

    player_results = %{
      user_id => %{participation: :played, result: :win, team: :north_south, position: :north}
    }

    # Wrap save_game_result in the same transaction the hook uses, but force a
    # rollback after the profile increment — asserting atomicity.
    result =
      Repo.transaction(fn ->
        {:ok, _} = Profiles.apply_completed_game(player_results, :north_south)
        Repo.rollback(:forced)
      end)

    assert {:error, :forced} = result
    assert Repo.aggregate(PlayerProfile, :count) == 0
  end

  describe "live rating update (PID-47)" do
    test "a 4-human game moves all four ratings (winners up, losers down, sigma shrinks)" do
      [n, e, s, w] = ids = for _ <- 1..4, do: player_id()
      {dmu, dsig} = Rating.default()

      # north/south win, east/west lose.
      complete_4human("RATED", {n, e, s, w}, :north_south)

      for id <- ids do
        p = profile(id)
        assert p.rating_games_count == 1
        assert p.rating_sigma < dsig
      end

      # Winners' mu up, losers' mu down.
      assert profile(n).rating_mu > dmu
      assert profile(s).rating_mu > dmu
      assert profile(e).rating_mu < dmu
      assert profile(w).rating_mu < dmu
    end

    test "single-player / bots-only game leaves ratings at default (counters still move)" do
      human = player_id()

      # Only one human seat recorded (rest are pure bots, never in player_results).
      results = %{human => result_for(:north_south, :north_south, :north)}
      seed_completed("SOLO", :north_south, results)

      {:ok, _} = Profiles.apply_completed_game(results, :north_south)

      # Untouched ratings hold the (rounded) schema default, not Rating.default/0.
      p = profile(human)
      assert p.games_played == 1
      assert p.rating_mu == 25.0
      assert p.rating_sigma == 8.333
      assert p.rating_games_count == 0
    end

    test "a 3-human game leaves ratings untouched but bumps counters" do
      [a, b, c] = ids = for _ <- 1..3, do: player_id()

      results = %{
        a => result_for(:north_south, :north_south, :north),
        b => result_for(:east_west, :north_south, :east),
        c => result_for(:north_south, :north_south, :south)
      }

      seed_completed("THREE", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south)

      for id <- ids do
        p = profile(id)
        assert p.games_played == 1
        assert p.rating_mu == 25.0
        assert p.rating_sigma == 8.333
        assert p.rating_games_count == 0
      end
    end

    test "idempotent re-fire does not double-move ratings" do
      [n, e, s, w] = for _ <- 1..4, do: player_id()

      {:ok, room} = RoomManager.create_room(n, %{name: "RatingIdempotent"})
      {:ok, _, _} = RoomManager.join_room(room.code, e)
      {:ok, _, _} = RoomManager.join_room(room.code, s)
      {:ok, _, _} = RoomManager.join_room(room.code, w)
      # Only a game being played can end.
      PidroServer.RoomFixtures.ready_room(room.code)

      game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
      send(GenServer.whereis(RoomManager), game_over)

      saved = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)
      after_first = snapshot()

      # Fire again; the room_code short-circuit must keep ratings put.
      send(GenServer.whereis(RoomManager), game_over)
      _ = :sys.get_state(GenServer.whereis(RoomManager))

      assert Repo.aggregate(GameStats, :count) == 1

      for id <- saved.player_ids do
        assert profile(id).rating_games_count == 1
      end

      assert_profiles_match(after_first, snapshot())
    end

    test "a forced stats-insert failure rolls back the rating move" do
      [n, e, s, w] = for _ <- 1..4, do: player_id()

      results = %{
        n => result_for(:north_south, :north_south, :north),
        e => result_for(:east_west, :north_south, :east),
        s => result_for(:north_south, :north_south, :south),
        w => result_for(:east_west, :north_south, :west)
      }

      result =
        Repo.transaction(fn ->
          {:ok, _} = Profiles.apply_completed_game(results, :north_south)
          Repo.rollback(:forced)
        end)

      assert {:error, :forced} = result
      assert Repo.aggregate(PlayerProfile, :count) == 0
    end

    test "real completion path equals a fresh rerate_all/0 (acceptance c)" do
      [a, b, c, d, e, f] = for _ <- 1..6, do: player_id()

      # Drive N rated 4-human games through the real Stats save path, with
      # strictly increasing completed_at so arrival order == the rebuild's total
      # order [completed_at, inserted_at, id].
      base = ~U[2026-06-07 12:00:00Z]

      complete_4human("G1", {a, b, c, d}, :north_south, DateTime.add(base, 0))
      complete_4human("G2", {a, c, e, b}, :east_west, DateTime.add(base, 1))
      complete_4human("G3", {e, f, a, d}, :north_south, DateTime.add(base, 2))
      complete_4human("G4", {b, d, f, c}, :east_west, DateTime.add(base, 3))
      complete_4human("G5", {a, b, e, f}, :north_south, DateTime.add(base, 4))

      live = snapshot()

      # A fresh from-scratch rebuild over the same game_stats rows is the source
      # of truth; the live per-game move must match it exactly.
      assert {:ok, %{games: 5}} = Profiles.rerate_all()

      assert_profiles_match(live, snapshot())
    end
  end

  describe "XP per game (PID-198)" do
    test "a game with four humans writes one row each, from the same XP as the total" do
      ids = for _ <- 1..4, do: player_id()
      seats = Map.new(Enum.zip([:north, :east, :south, :west], ids), &human_seat/1)
      room = %{code: "XP4ROWS", created_at: DateTime.utc_now(), seats: seats}

      assert {:ok, _} =
               Stats.save_completed_game(
                 room,
                 :north_south,
                 %{north_south: 62, east_west: 45},
                 nil,
                 game_instance_id: "xp-4-rows"
               )

      game = Repo.get_by!(GameStats, game_instance_id: "xp-4-rows")
      rows = Repo.all(GameXp)

      assert Enum.sort(Enum.map(rows, & &1.user_id)) == Enum.sort(ids)

      for row <- rows do
        assert row.game_stats_id == game.id
        assert row.earned_at == game.completed_at
        assert row.xp == profile(row.user_id).veteran_xp
      end

      # Winners 62 + 50 bonus, losers 45.
      assert rows |> Enum.map(& &1.xp) |> Enum.sort() == [45, 45, 112, 112]

      # The same game saved again writes nothing new.
      assert :ok =
               Stats.save_completed_game(
                 room,
                 :north_south,
                 %{north_south: 62, east_west: 45},
                 nil,
                 game_instance_id: "xp-4-rows"
               )

      assert Repo.aggregate(GameXp, :count) == 4
    end

    test "bots get no rows; the humans at their table do" do
      [north, south] = for _ <- 1..2, do: player_id()

      seats = %{
        north: Seat.new_human(:north, north),
        east: Seat.new_bot(:east, self()),
        south: Seat.new_human(:south, south),
        west: Seat.new_bot(:west, self())
      }

      room = %{code: "XPBOTS", created_at: DateTime.utc_now(), seats: seats}

      assert {:ok, _} =
               Stats.save_completed_game(room, :east_west, %{north_south: 20, east_west: 62})

      assert GameXp |> Repo.all() |> Enum.map(& &1.user_id) |> Enum.sort() ==
               Enum.sort([north, south])
    end

    test "one game never counts twice for a player, even if applied again" do
      user_id = player_id()
      results = %{user_id => result_for(:north_south, :north_south, :north)}
      scores = %{north_south: 62, east_west: 45}
      {:ok, game} = seed_completed("XPTWICE", :north_south, results)

      for _ <- 1..2,
          do:
            {:ok, _} =
              Profiles.apply_completed_game(results, :north_south, scores, %{}, game: game)

      assert [%GameXp{xp: 112}] = Repo.all(GameXp)
    end

    test "the Classic import writes no rows" do
      user_id = player_id()
      {:ok, _} = Profiles.import_legacy_progression(user_id, %{xp: 5_000})

      assert profile(user_id).veteran_xp == 5_000
      assert Repo.all(GameXp) == []
    end

    test "deleting the account deletes the player's rows" do
      [user_id, other_id] = for _ <- 1..2, do: player_id()
      seats = %{north: Seat.new_human(:north, user_id), east: Seat.new_human(:east, other_id)}
      room = %{code: "XPDEL", created_at: DateTime.utc_now(), seats: seats}
      {:ok, _} = Stats.save_completed_game(room, :north_south, %{north_south: 62, east_west: 45})

      {:ok, _} = user_id |> Auth.get_user() |> Auth.delete_user()

      assert [%GameXp{user_id: ^other_id}] = Repo.all(GameXp)
    end
  end

  describe "veteran XP (PID-49)" do
    test "awards XP to ALL participants of a 4-human game, incl. losers" do
      [n, e, s, w] = for _ <- 1..4, do: player_id()

      results = %{
        n => result_for(:north_south, :north_south, :north),
        e => result_for(:east_west, :north_south, :east),
        s => result_for(:north_south, :north_south, :south),
        w => result_for(:east_west, :north_south, :west)
      }

      scores = %{north_south: 62, east_west: 45}
      seed_completed("XP4", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south, scores)

      # Winners: 62 + 50 = 112; losers: 45 (no bonus).
      for id <- [n, s] do
        p = profile(id)
        assert p.veteran_xp == 112
        assert p.veteran_level == Progression.level_for_xp(112)
      end

      for id <- [e, w] do
        p = profile(id)
        assert p.veteran_xp == 45
        assert p.veteran_level == Progression.level_for_xp(45)
      end
    end

    test "single-player / bot-filled game still pays XP (NOT rated-gated)" do
      human = player_id()
      results = %{human => result_for(:north_south, :north_south, :north)}
      scores = %{north_south: 62, east_west: 45}

      seed_completed("XPSOLO", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south, scores)

      p = profile(human)
      # XP accrues (dedication) while the skill rating stays untouched.
      assert p.veteran_xp == 112
      assert p.veteran_level == Progression.level_for_xp(112)
      assert p.games_played == 1
      assert p.rating_games_count == 0
    end

    test "an :abandoned seat earns XP like the counters credit it" do
      user_id = player_id()

      results = %{
        user_id => %{
          participation: :abandoned,
          result: :win,
          team: :north_south,
          position: :north
        }
      }

      scores = %{north_south: 62, east_west: 45}
      seed_completed("XPABANDON", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south, scores)

      p = profile(user_id)
      assert p.veteran_xp == 112
    end

    test "live completion XP/level == rebuild_all/0 XP/level (parity)" do
      [a, b, c, d, e, f] = for _ <- 1..6, do: player_id()

      complete_4human_xp("PG1", {a, b, c, d}, :north_south, %{north_south: 62, east_west: 30})
      complete_4human_xp("PG2", {a, c, e, b}, :east_west, %{north_south: 40, east_west: 62})
      complete_4human_xp("PG3", {e, f, a, d}, :north_south, %{north_south: 62, east_west: 51})
      complete_4human_xp("PG4", {b, d, f, c}, :east_west, %{north_south: 22, east_west: 62})

      live = xp_snapshot()

      assert {:ok, _} = Profiles.rebuild_all()

      rebuilt = xp_snapshot()
      assert Map.keys(live) |> Enum.sort() == Map.keys(rebuilt) |> Enum.sort()

      Enum.each(live, fn {user_id, {xp, level}} ->
        assert {xp, level} == Map.fetch!(rebuilt, user_id)
      end)
    end

    test "rebuild tolerates legacy string-keyed final_scores and missing team score" do
      u1 = player_id()
      u2 = player_id()

      results = %{
        u1 => result_for(:north_south, :north_south, :north),
        u2 => result_for(:east_west, :north_south, :east)
      }

      # Persist with a final_scores map missing the east_west key (legacy floor 0).
      {:ok, _} =
        Stats.save_game_result(%{
          room_code: "XPLEGACY",
          winner: :north_south,
          final_scores: %{north_south: 62},
          duration_seconds: 100,
          completed_at: DateTime.utc_now(),
          player_ids: [u1, u2],
          player_results: results
        })

      assert {:ok, reb_u1} = Profiles.rebuild_from_history(u1)
      assert {:ok, reb_u2} = Profiles.rebuild_from_history(u2)

      # Winner: 62 + 50; loser: missing score floors to 0.
      assert reb_u1.veteran_xp == 112
      assert reb_u2.veteran_xp == 0
    end
  end

  describe "achievements (PID-50)" do
    alias PidroServer.Profiles.Achievement

    test "10th game awards :player exactly at the threshold, not before" do
      u = player_id()

      for n <- 1..9 do
        complete_solo("PLAYER#{n}", u, :north_south, DateTime.add(@base, n))
      end

      refute "player" in earned_keys(u)

      complete_solo("PLAYER10", u, :north_south, DateTime.add(@base, 10))
      assert "player" in earned_keys(u)
    end

    test "5th win awards :winner exactly at the threshold" do
      u = player_id()

      # 4 wins, then a loss, then the 5th win.
      for n <- 1..4 do
        complete_solo("WIN#{n}", u, :north_south, DateTime.add(@base, n))
      end

      refute "winner" in earned_keys(u)
      # A loss does not count toward wins.
      complete_solo("WINLOSS", u, :east_west, DateTime.add(@base, 5))
      refute "winner" in earned_keys(u)

      complete_solo("WIN5", u, :north_south, DateTime.add(@base, 6))
      assert "winner" in earned_keys(u)
    end

    test "3 straight wins award :winstreak; a prior loss does not block it" do
      u = player_id()

      complete_solo("WS_L", u, :east_west, DateTime.add(@base, 1))
      complete_solo("WS_W1", u, :north_south, DateTime.add(@base, 2))
      complete_solo("WS_W2", u, :north_south, DateTime.add(@base, 3))
      refute "winstreak" in earned_keys(u)

      complete_solo("WS_W3", u, :north_south, DateTime.add(@base, 4))
      assert "winstreak" in earned_keys(u)
    end

    test "an opponent-shutout win awards :ace" do
      u = player_id()

      complete_solo("ACE_NO", u, :north_south, DateTime.add(@base, 1), %{
        north_south: 62,
        east_west: 10
      })

      refute "ace" in earned_keys(u)

      complete_solo("ACE_YES", u, :north_south, DateTime.add(@base, 2), %{
        north_south: 62,
        east_west: -3
      })

      assert "ace" in earned_keys(u)
    end

    test "a negative-finish game awards :the_loser" do
      u = player_id()

      # User sits on north_south, loses (east_west wins), and finishes negative.
      complete_solo("LOSER", u, :east_west, DateTime.add(@base, 1), %{
        north_south: -8,
        east_west: 62
      })

      assert "the_loser" in earned_keys(u)
    end

    test ":partnership earns at 10 wins with the SAME partner; 9 does not" do
      # n + s are fixed partners on north_south; they win 9 games together.
      [n, e, s, w] = for _ <- 1..4, do: player_id()

      for i <- 1..9 do
        complete_4human("PART_SAME#{i}", {n, e, s, w}, :north_south, DateTime.add(@base, i))
      end

      refute "partnership" in earned_keys(n)
      refute "partnership" in earned_keys(s)

      # The 10th win with the same partner crosses the threshold for both winners.
      complete_4human("PART_SAME10", {n, e, s, w}, :north_south, DateTime.add(@base, 10))
      assert "partnership" in earned_keys(n)
      assert "partnership" in earned_keys(s)

      # The losers (e, w) won 0 games, so they never earn.
      refute "partnership" in earned_keys(e)
      refute "partnership" in earned_keys(w)
    end

    test ":partnership does NOT earn when 10 wins are spread across DIFFERENT partners" do
      # `hero` wins 10 north_south games, but with a DIFFERENT partner each time,
      # so no single partner reaches the threshold.
      hero = player_id()

      for i <- 1..10 do
        partner = player_id()
        e = player_id()
        w = player_id()
        # hero sits north, the fresh partner sits south — both win.
        complete_4human(
          "PART_DIFF#{i}",
          {hero, e, partner, w},
          :north_south,
          DateTime.add(@base, i)
        )
      end

      refute "partnership" in earned_keys(hero)
    end

    test ":partnership does not count a solo / bot-filled win (no real partner)" do
      solo = player_id()

      for i <- 1..12 do
        complete_solo("PART_SOLO#{i}", solo, :north_south, DateTime.add(@base, i))
      end

      refute "partnership" in earned_keys(solo)
    end

    test "awards are permanent + idempotent (no dup rows, no downgrade on rebuild)" do
      u = player_id()

      complete_solo("PERM_W1", u, :north_south, DateTime.add(@base, 1))
      complete_solo("PERM_W2", u, :north_south, DateTime.add(@base, 2))
      complete_solo("PERM_W3", u, :north_south, DateTime.add(@base, 3))
      assert "winstreak" in earned_keys(u)

      # Break the streak with later losses — the earned row must survive.
      complete_solo("PERM_L1", u, :east_west, DateTime.add(@base, 4))
      complete_solo("PERM_L2", u, :east_west, DateTime.add(@base, 5))
      assert "winstreak" in earned_keys(u)

      # A full rebuild recomputes a now-broken streak but never removes the row.
      assert {:ok, _} = Profiles.rebuild_all()
      assert "winstreak" in earned_keys(u)

      # No duplicate rows for the key.
      count =
        Repo.aggregate(
          from(a in Achievement, where: a.user_id == ^u and a.achievement_key == "winstreak"),
          :count
        )

      assert count == 1
    end

    test "achievements live in the summary's achievements_unlocked; not re-reported next game" do
      u = player_id()

      for n <- 1..9 do
        complete_solo("RET#{n}", u, :north_south, DateTime.add(@base, n))
      end

      # The 10th completion crosses :player; capture its summary directly.
      results = %{u => result_for(:north_south, :north_south, :north)}
      scores = %{north_south: 62, east_west: 30}
      seed_completed("RET10", :north_south, results, DateTime.add(@base, 10))
      assert {:ok, summaries} = Profiles.apply_completed_game(results, :north_south, scores)

      keys = Enum.map(summaries[u].achievements_unlocked, & &1.key)
      assert "player" in keys

      # A subsequent game does NOT re-report :player (idempotent).
      results2 = %{u => result_for(:north_south, :north_south, :north)}
      seed_completed("RET11", :north_south, results2, DateTime.add(@base, 11))
      assert {:ok, summaries2} = Profiles.apply_completed_game(results2, :north_south, scores)
      keys2 = Enum.map(summaries2[u].achievements_unlocked, & &1.key)
      refute "player" in keys2
    end

    test "live award set == rebuild award set (headline parity guard)" do
      [a, b, c, d] = for _ <- 1..4, do: player_id()

      # A scripted sequence exercising counters, streaks, shutouts, partnered wins.
      complete_4human("P1", {a, b, c, d}, :north_south, DateTime.add(@base, 1), %{
        north_south: 62,
        east_west: -5
      })

      complete_4human("P2", {a, b, c, d}, :north_south, DateTime.add(@base, 2))
      complete_4human("P3", {a, b, c, d}, :north_south, DateTime.add(@base, 3))
      complete_4human("P4", {a, b, c, d}, :east_west, DateTime.add(@base, 4))

      live = earned_snapshot([a, b, c, d])

      assert {:ok, _} = Profiles.rebuild_all()

      rebuilt = earned_snapshot([a, b, c, d])
      assert live == rebuilt
    end

    test ":partnership live award == rebuild award (parity at the threshold)" do
      [n, e, s, w] = for _ <- 1..4, do: player_id()

      for i <- 1..10 do
        complete_4human("PARTPAR#{i}", {n, e, s, w}, :north_south, DateTime.add(@base, i))
      end

      live = earned_snapshot([n, e, s, w])
      assert "partnership" in live[n]
      assert "partnership" in live[s]

      assert {:ok, _} = Profiles.rebuild_all()

      rebuilt = earned_snapshot([n, e, s, w])
      assert live == rebuilt
    end

    test "rebuild is idempotent (running it twice awards nothing the second time)" do
      u = player_id()
      complete_solo("IDEM1", u, :north_south, DateTime.add(@base, 1))
      complete_solo("IDEM2", u, :north_south, DateTime.add(@base, 2))
      complete_solo("IDEM3", u, :north_south, DateTime.add(@base, 3))

      assert {:ok, _} = Profiles.rebuild_all()
      first = earned_keys(u)
      assert {:ok, _} = Profiles.rebuild_all()
      assert earned_keys(u) == first

      assert Repo.aggregate(from(a in Achievement, where: a.user_id == ^u), :count) ==
               length(first)
    end

    test "dormant achievements never appear after completions or a rebuild" do
      [a, b, c, d] = for _ <- 1..4, do: player_id()
      complete_4human("DORM", {a, b, c, d}, :north_south, DateTime.add(@base, 1))
      assert {:ok, _} = Profiles.rebuild_all()

      dormant = ~w(homerun forcer full_house unstoppable)
      all_earned = Repo.all(Achievement) |> Enum.map(& &1.achievement_key)
      refute Enum.any?(dormant, &(&1 in all_earned))
    end

    test "adding a def is trivial: a synthetic active def is picked up by both paths" do
      # Inject a config override so :player's threshold is 1 — i.e. exactly the
      # kind of data-only change "adding/tuning a def" represents — and assert
      # BOTH the live path and rebuild pick it up with no other code change.
      Application.put_env(:pidro_server, PidroServer.Achievements.Catalog,
        thresholds: %{player: 1}
      )

      on_exit(fn -> Application.delete_env(:pidro_server, PidroServer.Achievements.Catalog) end)

      u = player_id()
      complete_solo("TRIV", u, :north_south, DateTime.add(@base, 1))
      assert "player" in earned_keys(u)

      assert {:ok, _} = Profiles.rebuild_all()
      assert "player" in earned_keys(u)
    end
  end

  describe "post-game summary (PID-52)" do
    test "a 4-human rated game returns a summary per participant (rated, rating, xp)" do
      [n, e, s, w] = for _ <- 1..4, do: player_id()

      results = %{
        n => result_for(:north_south, :north_south, :north),
        e => result_for(:east_west, :north_south, :east),
        s => result_for(:north_south, :north_south, :south),
        w => result_for(:east_west, :north_south, :west)
      }

      scores = %{north_south: 62, east_west: 45}
      seed_completed("SUM4", :north_south, results, nil, scores)
      assert {:ok, summaries} = Profiles.apply_completed_game(results, :north_south, scores)

      assert Map.keys(summaries) |> Enum.sort() == Enum.sort([n, e, s, w])

      for {id, expected_xp} <- [{n, 112}, {s, 112}, {e, 45}, {w, 45}] do
        summary = summaries[id]
        assert summary.rated == true
        assert summary.xp_earned == expected_xp
        assert is_map(summary.rating)
        assert summary.rating.direction in ["up", "down", "none"]
      end
    end

    test "a single-player / bot-filled game returns rated: false, rating: nil, full Veteran block" do
      human = player_id()
      results = %{human => result_for(:north_south, :north_south, :north)}
      scores = %{north_south: 62, east_west: 45}

      seed_completed("SUMSOLO", :north_south, results, nil, scores)
      assert {:ok, summaries} = Profiles.apply_completed_game(results, :north_south, scores)

      summary = summaries[human]
      assert summary.rated == false
      assert summary.rating == nil
      assert summary.xp_earned == 112
      assert summary.veteran_level == Progression.level_for_xp(112)
      assert summary.veteran_title == Progression.title_for_level(summary.veteran_level)
      assert is_map(summary.veteran_progress)
    end

    test "a rolled-back completion leaves no profile changes and emits no summary" do
      [n, e, s, w] = for _ <- 1..4, do: player_id()

      results = %{
        n => result_for(:north_south, :north_south, :north),
        e => result_for(:east_west, :north_south, :east),
        s => result_for(:north_south, :north_south, :south),
        w => result_for(:east_west, :north_south, :west)
      }

      # The broadcast lives in RoomManager and only fires on a committed {:ok,
      # summaries}; a rolled-back transaction returns {:error, _} so nothing is
      # ever surfaced.
      result =
        Repo.transaction(fn ->
          {:ok, _summaries} = Profiles.apply_completed_game(results, :north_south)
          Repo.rollback(:forced)
        end)

      assert {:error, :forced} = result
      assert Repo.aggregate(PlayerProfile, :count) == 0
    end

    test "partner: the run with this partner survives games with others; a loss resets it" do
      [hero, nora, other, o1, o2] = for _ <- 1..5, do: player_id()
      Repo.update_all(from(u in User, where: u.id == ^nora), set: [display_name: "Nora"])

      play = fn code, partner, winner, i ->
        results = %{
          hero => result_for(:north_south, winner, :north),
          o1 => result_for(:east_west, winner, :east),
          partner => result_for(:north_south, winner, :south),
          o2 => result_for(:east_west, winner, :west)
        }

        seed_completed(code, winner, results, DateTime.add(@base, i))
        {:ok, summaries} = Profiles.apply_completed_game(results, winner, %{})
        summaries
      end

      play.("RUN1", nora, :north_south, 1)
      play.("RUN2", nora, :east_west, 2)
      play.("RUN3", nora, :north_south, 3)
      # A loss with someone else does not break the run with Nora.
      play.("RUN4", other, :east_west, 4)
      summaries = play.("RUN5", nora, :north_south, 5)

      assert summaries[hero].partner == %{
               user_id: nora,
               display_name: "Nora",
               games_together: 4,
               wins_in_a_row: 2
             }

      assert %{user_id: ^hero, games_together: 4, wins_in_a_row: 2} = summaries[nora].partner
      assert %{user_id: ^o2, games_together: 5, wins_in_a_row: 0} = summaries[o1].partner

      summaries = play.("RUN6", nora, :east_west, 6)
      assert %{games_together: 5, wins_in_a_row: 0} = summaries[hero].partner
    end

    test "partner is nil beside a bot or a guest" do
      [hero, o1, o2] = for _ <- 1..3, do: player_id()
      guest = AccountsFixtures.guest_fixture().id

      solo = %{hero => result_for(:north_south, :north_south, :north)}
      seed_completed("BOTPART", :north_south, solo)

      assert {:ok, %{^hero => %{partner: nil}}} =
               Profiles.apply_completed_game(solo, :north_south, %{})

      results = %{
        hero => result_for(:north_south, :north_south, :north),
        o1 => result_for(:east_west, :north_south, :east),
        guest => result_for(:north_south, :north_south, :south),
        o2 => result_for(:east_west, :north_south, :west)
      }

      seed_completed("GUESTPART", :north_south, results)
      assert {:ok, summaries} = Profiles.apply_completed_game(results, :north_south, %{})
      assert summaries[hero].partner == nil
      assert %{user_id: ^hero, games_together: 1, wins_in_a_row: 1} = summaries[guest].partner
    end

    test "idempotent re-fire produces no second progression_summary broadcast" do
      [n, e, s, w] = for _ <- 1..4, do: player_id()

      {:ok, room} = RoomManager.create_room(n, %{name: "SummaryIdempotent"})
      {:ok, _, _} = RoomManager.join_room(room.code, e)
      {:ok, _, _} = RoomManager.join_room(room.code, s)
      {:ok, _, _} = RoomManager.join_room(room.code, w)
      # Only a game being played can end.
      PidroServer.RoomFixtures.ready_room(room.code)

      Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room.code}")

      game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
      send(GenServer.whereis(RoomManager), game_over)

      assert_receive {:progression_summary, room_code, summaries}, 1000
      assert room_code == room.code
      assert map_size(summaries) == 4

      # Re-fire: the GameStats short-circuit returns :ok → no second broadcast.
      send(GenServer.whereis(RoomManager), game_over)
      _ = :sys.get_state(GenServer.whereis(RoomManager))
      refute_receive {:progression_summary, _, _}, 200
    end
  end

  describe "playstyle accumulation (PID-51)" do
    test "live accumulation across two games; second game adds to the first" do
      a = player_id()
      b = player_id()

      results = %{
        a => result_for(:north_south, :north_south, :north),
        b => result_for(:east_west, :north_south, :east)
      }

      # a wins 2 of 3 hands (sum 13); b wins 1 (sum 9).
      bidding = %{
        a => %{"attempts" => 3, "wins" => 2, "won_bid_sum" => 13},
        b => %{"attempts" => 3, "wins" => 1, "won_bid_sum" => 9}
      }

      seed_completed("PS1", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south, %{}, bidding)

      pa = profile(a)
      assert pa.playstyle_bidding_attempts == 3
      assert pa.playstyle_bidding_wins == 2
      assert pa.avg_winning_bid_sum == 13
      assert pa.avg_winning_bid_count == 2

      pb = profile(b)
      assert pb.playstyle_bidding_attempts == 3
      assert pb.playstyle_bidding_wins == 1
      assert pb.avg_winning_bid_sum == 9
      assert pb.avg_winning_bid_count == 1

      # A second completed game ADDS to the accumulators.
      seed_completed("PS2", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south, %{}, bidding)

      pa2 = profile(a)
      assert pa2.playstyle_bidding_attempts == 6
      assert pa2.playstyle_bidding_wins == 4
      assert pa2.avg_winning_bid_sum == 26
      assert pa2.avg_winning_bid_count == 4
    end

    test "single-player / bot-filled game still accumulates the human's bidding facts" do
      human = player_id()
      results = %{human => result_for(:north_south, :north_south, :north)}
      # 5 hands, the human won 2 (sum 15); bots never appear in the map.
      bidding = %{human => %{"attempts" => 5, "wins" => 2, "won_bid_sum" => 15}}

      seed_completed("PSSOLO", :north_south, results)
      {:ok, _} = Profiles.apply_completed_game(results, :north_south, %{}, bidding)

      p = profile(human)
      assert p.playstyle_bidding_attempts == 5
      assert p.playstyle_bidding_wins == 2
      assert p.avg_winning_bid_sum == 15
      assert p.avg_winning_bid_count == 2
    end

    test "live == rebuild parity for the four accumulators" do
      [a, b, c, d] = for _ <- 1..4, do: player_id()

      complete_4human_ps("PSP1", {a, b, c, d}, :north_south, DateTime.add(@base, 1), %{
        a => %{"attempts" => 4, "wins" => 2, "won_bid_sum" => 13},
        b => %{"attempts" => 4, "wins" => 1, "won_bid_sum" => 7},
        c => %{"attempts" => 4, "wins" => 1, "won_bid_sum" => 8},
        d => %{"attempts" => 4, "wins" => 0, "won_bid_sum" => 0}
      })

      complete_4human_ps("PSP2", {a, b, c, d}, :east_west, DateTime.add(@base, 2), %{
        a => %{"attempts" => 3, "wins" => 0, "won_bid_sum" => 0},
        b => %{"attempts" => 3, "wins" => 2, "won_bid_sum" => 17},
        c => %{"attempts" => 3, "wins" => 1, "won_bid_sum" => 6},
        d => %{"attempts" => 3, "wins" => 0, "won_bid_sum" => 0}
      })

      live = playstyle_snapshot()

      assert {:ok, _} = Profiles.rebuild_all()

      rebuilt = playstyle_snapshot()
      assert Map.keys(live) |> Enum.sort() == Map.keys(rebuilt) |> Enum.sort()

      Enum.each(live, fn {user_id, facts} ->
        assert facts == Map.fetch!(rebuilt, user_id)
      end)
    end

    test "a nil player_bidding row contributes zero on rebuild (no crash, no negative)" do
      u = player_id()
      results = %{u => result_for(:north_south, :north_south, :north)}

      # Row written WITHOUT player_bidding (pre-column / events unavailable).
      {:ok, _} =
        Stats.save_game_result(%{
          room_code: "PSNIL",
          winner: :north_south,
          final_scores: %{north_south: 62, east_west: 45},
          duration_seconds: 100,
          completed_at: DateTime.add(@base, 1),
          player_ids: [u],
          player_results: results
        })

      assert {:ok, reb} = Profiles.rebuild_from_history(u)
      assert reb.playstyle_bidding_attempts == 0
      assert reb.playstyle_bidding_wins == 0
      assert reb.avg_winning_bid_sum == 0
      assert reb.avg_winning_bid_count == 0
    end

    test "a forced failure rolls back playstyle accumulation (no partial inc)" do
      u = player_id()
      results = %{u => result_for(:north_south, :north_south, :north)}
      bidding = %{u => %{"attempts" => 3, "wins" => 2, "won_bid_sum" => 13}}

      result =
        Repo.transaction(fn ->
          {:ok, _} = Profiles.apply_completed_game(results, :north_south, %{}, bidding)
          Repo.rollback(:forced)
        end)

      assert {:error, :forced} = result
      assert Repo.aggregate(PlayerProfile, :count) == 0
    end
  end

  # --- helpers ---

  # Seed a game_stats row carrying player_bidding AND run the live completion
  # update, mirroring the real save path so live and rebuild see the same map.
  defp complete_4human_ps(room_code, {n, e, s, w}, winner, completed_at, bidding) do
    results = %{
      n => result_for(:north_south, winner, :north),
      e => result_for(:east_west, winner, :east),
      s => result_for(:north_south, winner, :south),
      w => result_for(:east_west, winner, :west)
    }

    {:ok, _} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: %{north_south: 62, east_west: 45},
        bid_amount: 8,
        bid_team: :north_south,
        duration_seconds: 300,
        completed_at: completed_at,
        player_ids: Map.keys(results),
        player_results: results,
        player_bidding: bidding
      })

    {:ok, _} = Profiles.apply_completed_game(results, winner, %{}, bidding)
    results
  end

  defp playstyle_snapshot do
    Repo.all(PlayerProfile)
    |> Map.new(fn p ->
      {p.user_id,
       %{
         attempts: p.playstyle_bidding_attempts,
         wins: p.playstyle_bidding_wins,
         won_bid_sum: p.avg_winning_bid_sum,
         won_bid_count: p.avg_winning_bid_count
       }}
    end)
  end

  # Seed + apply a single-human game (the rest of the table is bots / absent),
  # with controllable winner, completed_at, and scores.
  # The user always sits on north_south; pass winner: :north_south for a win,
  # :east_west for a loss.
  defp complete_solo(room_code, user_id, winner, completed_at, scores \\ nil) do
    results = %{user_id => result_for(:north_south, winner, :north)}
    scores = scores || %{north_south: 62, east_west: 45}

    {:ok, _} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: scores,
        bid_amount: 8,
        bid_team: :north_south,
        duration_seconds: 300,
        completed_at: completed_at,
        player_ids: Map.keys(results),
        player_results: results
      })

    {:ok, _} = Profiles.apply_completed_game(results, winner, scores)
    results
  end

  defp earned_keys(user_id) do
    user_id |> Profiles.list_achievements() |> Enum.map(& &1.achievement_key) |> Enum.sort()
  end

  defp earned_snapshot(user_ids) do
    Map.new(user_ids, fn id -> {id, earned_keys(id)} end)
  end

  defp complete_4human_xp(room_code, {n, e, s, w}, winner, scores) do
    results = %{
      n => result_for(:north_south, winner, :north),
      e => result_for(:east_west, winner, :east),
      s => result_for(:north_south, winner, :south),
      w => result_for(:east_west, winner, :west)
    }

    {:ok, _} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: scores,
        bid_amount: 8,
        bid_team: :north_south,
        duration_seconds: 300,
        completed_at: DateTime.utc_now(),
        player_ids: Map.keys(results),
        player_results: results
      })

    {:ok, _} = Profiles.apply_completed_game(results, winner, scores)
    results
  end

  defp xp_snapshot do
    Repo.all(PlayerProfile)
    |> Map.new(fn p -> {p.user_id, {p.veteran_xp, p.veteran_level}} end)
  end

  defp result_for(team, winner, position) do
    %{
      participation: :played,
      result: if(team == winner, do: :win, else: :loss),
      team: team,
      position: position
    }
  end

  # Seed a game_stats row AND run the live completion update, mirroring the
  # save_completed_game/4 transaction (insert + apply_completed_game). The same
  # `scores` are persisted AND passed live, so the live and rebuild paths agree
  # on score-derived achievements (ace / the_loser).
  defp complete_4human(room_code, {n, e, s, w}, winner, completed_at \\ nil, scores \\ nil) do
    results = %{
      n => result_for(:north_south, winner, :north),
      e => result_for(:east_west, winner, :east),
      s => result_for(:north_south, winner, :south),
      w => result_for(:east_west, winner, :west)
    }

    scores = scores || %{north_south: 62, east_west: 45}
    seed_completed(room_code, winner, results, completed_at, scores)
    {:ok, _} = Profiles.apply_completed_game(results, winner, scores)
    results
  end

  defp seed_completed(room_code, winner, results, completed_at \\ nil, scores \\ nil) do
    {:ok, _} =
      Stats.save_game_result(%{
        room_code: room_code,
        winner: winner,
        final_scores: scores || %{north_south: 62, east_west: 45},
        bid_amount: 8,
        bid_team: :north_south,
        duration_seconds: 300,
        completed_at: completed_at || DateTime.utc_now(),
        player_ids: Map.keys(results),
        player_results: results
      })
  end

  defp player_id, do: AccountsFixtures.user_fixture().id

  defp human_seat({position, user_id}), do: {position, Seat.new_human(position, user_id)}

  defp profile(user_id) do
    {:ok, p} = Profiles.get_or_create_profile(user_id)
    p
  end

  defp snapshot do
    Repo.all(PlayerProfile)
    |> Map.new(fn p -> {p.user_id, {p.rating_mu, p.rating_sigma, p.rating_games_count}} end)
  end

  defp assert_profiles_match(a, b) do
    assert Map.keys(a) |> Enum.sort() == Map.keys(b) |> Enum.sort()

    Enum.each(a, fn {user_id, {mu, sigma, count}} ->
      {b_mu, b_sigma, b_count} = Map.fetch!(b, user_id)
      assert_in_delta mu, b_mu, @delta
      assert_in_delta sigma, b_sigma, @delta
      assert count == b_count
    end)
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(_fun, 0), do: flunk("timed out waiting for condition")

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
end
