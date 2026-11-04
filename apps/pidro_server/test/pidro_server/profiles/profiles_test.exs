defmodule PidroServer.ProfilesTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Profiles
  alias PidroServer.Profiles.Achievement
  alias PidroServer.Profiles.GameXp
  alias PidroServer.Profiles.PlayerProfile
  alias PidroServer.Progression
  alias PidroServer.Stats

  defp insert_user do
    {:ok, user} =
      PidroServer.Accounts.Auth.register_user(%{
        username: "user_#{System.unique_integer([:positive])}",
        password: "password123"
      })

    user
  end

  defp result_for(team, winner, position) do
    %{
      participation: :played,
      result: if(team == winner, do: :win, else: :loss),
      team: team,
      position: position
    }
  end

  describe "get_or_create_profile/1" do
    test "creates a default row when none exists" do
      user_id = Ecto.UUID.generate()

      assert {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.user_id == user_id
      assert profile.games_played == 0
      assert profile.wins == 0
      assert profile.losses == 0
      assert profile.rating_mu == 25.0
      assert profile.rating_sigma == 8.333
      assert profile.rating_games_count == 0
      assert profile.veteran_level == 0
      assert profile.heritage_flags == %{}
    end

    test "returns the existing row on second call (no duplicate)" do
      user_id = Ecto.UUID.generate()

      assert {:ok, first} = Profiles.get_or_create_profile(user_id)
      assert {:ok, second} = Profiles.get_or_create_profile(user_id)

      assert first.id == second.id
      assert Repo.aggregate(PlayerProfile, :count) == 1
    end

    test "calling twice never raises and never creates a duplicate" do
      user_id = Ecto.UUID.generate()

      assert {:ok, _} = Profiles.get_or_create_profile(user_id)
      assert {:ok, _} = Profiles.get_or_create_profile(user_id)

      assert Repo.aggregate(from(p in PlayerProfile, where: p.user_id == ^user_id), :count) == 1
    end
  end

  describe "get_profile_for_screen/1" do
    test "lazily creates and returns win_rate 0.0 with no games" do
      user = insert_user()

      assert {:ok, view} = Profiles.get_profile_for_screen(user.id)
      assert view.games_played == 0
      assert view.win_rate == 0.0
      # PID-51: nil-on-empty (never won a bid), not a misleading 0.0.
      assert view.avg_winning_bid == nil
      assert view.first_seen_at == Repo.reload!(user).inserted_at
      assert is_integer(view.account_age_days)
    end

    test "fresh profile reports :insufficient playstyle (center needle, balanced, no rate)" do
      user = insert_user()

      assert {:ok, view} = Profiles.get_profile_for_screen(user.id)
      assert view.bidding_win_rate == nil
      assert view.aggression_insufficient == true
      assert view.aggression_needle == 0.5
      assert view.aggression_label == :balanced
      assert view.avg_winning_bid == nil
    end

    test "populated profile derives needle/label/avg_winning_bid from the accumulators" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      # 1 win in 4 attempts → rate 0.25 → needle 0.5 → :balanced. Avg bid 7.5.
      profile
      |> PlayerProfile.changeset(%{
        playstyle_bidding_wins: 1,
        playstyle_bidding_attempts: 4,
        avg_winning_bid_sum: 30,
        avg_winning_bid_count: 4
      })
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)

      rate = PidroServer.Playstyle.bidding_win_rate(1, 4)
      assert view.bidding_win_rate == rate
      assert view.aggression_insufficient == false
      assert view.aggression_needle == PidroServer.Playstyle.needle(rate)
      assert view.aggression_label == PidroServer.Playstyle.label(view.aggression_needle)
      assert view.avg_winning_bid == PidroServer.Playstyle.avg_winning_bid(30, 4)
      assert view.avg_winning_bid == 7.5
    end

    test "computes win_rate correctly for a populated profile" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      profile
      |> PlayerProfile.changeset(%{games_played: 4, wins: 3, losses: 1})
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.win_rate == 0.75
    end

    test "computes avg_winning_bid from sum/count" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      profile
      |> PlayerProfile.changeset(%{avg_winning_bid_sum: 30, avg_winning_bid_count: 3})
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.avg_winning_bid == 10.0
    end

    test "untouched profile reports veteran_level 1 (XP-derived, not raw 0) and empty heritage" do
      user = insert_user()

      assert {:ok, view} = Profiles.get_profile_for_screen(user.id)
      assert view.veteran_xp == 0
      assert view.veteran_level == 1
      assert view.veteran_title == "Rookie"
      assert view.veteran_progress == {0, 320}
      # Below the L100 cap: no prestige, no ring.
      assert view.veteran_prestige == 0
      assert view.veteran_prestige_progress == nil
      assert view.heritage == []
      assert view.heritage_flags == %{}
    end

    test "prestige + progress derive from stored XP past the L100 cap" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      profile
      |> PlayerProfile.changeset(%{veteran_xp: 1_300_000})
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.veteran_level == 100
      assert view.veteran_prestige == 1
      assert view.veteran_prestige_progress == {0, 500_000}
    end

    test "veteran fields derive from stored XP" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      # Stale/zero cached level on purpose; the screen recomputes from XP.
      profile
      |> PlayerProfile.changeset(%{veteran_xp: 200, veteran_level: 0})
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.veteran_xp == 200
      assert view.veteran_level == PidroServer.Progression.level_for_xp(200)
      assert view.veteran_title == PidroServer.Progression.title_for_level(view.veteran_level)
      assert view.veteran_progress == PidroServer.Progression.level_progress(200)
    end

    test "heritage display list reflects heritage_flags" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)

      profile
      |> PlayerProfile.changeset(%{
        heritage_flags: %{"played_pidro_one" => true, "legacy_level" => 73}
      })
      |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert Enum.map(view.heritage, & &1.key) == [:played_pidro_one, :legacy_level]
    end

    test "achievements list is empty for a fresh profile; catalog shows all locked" do
      user = insert_user()

      assert {:ok, view} = Profiles.get_profile_for_screen(user.id)
      assert view.achievements == []

      # The active catalog (6 defs) is present, all unearned; dormant not shown.
      assert length(view.achievements_catalog) == 6
      assert Enum.all?(view.achievements_catalog, &(&1.earned == false))
      keys = view.achievements_catalog |> Enum.map(& &1.key) |> Enum.sort()
      assert keys == Enum.sort(~w(player winner winstreak ace the_loser partnership)a)
      refute Enum.any?(view.achievements_catalog, &(&1.key in ~w(homerun forcer)a))
    end

    test "achievements list shows earned defs joined to catalog display copy" do
      user_id = Ecto.UUID.generate()
      assert :awarded = Profiles.award_achievement(user_id, :player, 1, %{count: 10})

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert [earned] = view.achievements
      assert earned.key == :player
      assert earned.name == "Player"
      assert earned.description == "Finish 10 games."
      assert earned.tier == 1
      assert %DateTime{} = earned.awarded_at

      # The earned def is flagged earned in the catalog view.
      player_catalog = Enum.find(view.achievements_catalog, &(&1.key == :player))
      assert player_catalog.earned == true
    end
  end

  describe "apply_completed_game/2" do
    test "winner gets games_played +1 and wins +1" do
      user_id = insert_user().id
      player_results = %{user_id => result_for(:north_south, :north_south, :north)}

      assert {:ok, _} = Profiles.apply_completed_game(player_results, :north_south)

      {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.games_played == 1
      assert profile.wins == 1
      assert profile.losses == 0
    end

    test "loser gets games_played +1 and losses +1" do
      user_id = insert_user().id
      player_results = %{user_id => result_for(:east_west, :north_south, :east)}

      assert {:ok, _} = Profiles.apply_completed_game(player_results, :north_south)

      {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.games_played == 1
      assert profile.wins == 0
      assert profile.losses == 1
    end

    test "creates profiles lazily for previously-unknown users" do
      u1 = insert_user().id
      u2 = insert_user().id

      player_results = %{
        u1 => result_for(:north_south, :north_south, :north),
        u2 => result_for(:east_west, :north_south, :east)
      }

      assert {:ok, _} = Profiles.apply_completed_game(player_results, :north_south)

      assert {:ok, %{wins: 1}} = Profiles.get_or_create_profile(u1)
      assert {:ok, %{losses: 1}} = Profiles.get_or_create_profile(u2)
    end

    test "abandoned-but-on-winning-team user counts as a win" do
      user_id = insert_user().id

      player_results = %{
        user_id => %{
          participation: :abandoned,
          result: :win,
          team: :north_south,
          position: :north
        }
      }

      assert {:ok, _} = Profiles.apply_completed_game(player_results, :north_south)

      {:ok, profile} = Profiles.get_or_create_profile(user_id)
      assert profile.wins == 1
    end

    test "skips non-UUID ids without crashing" do
      valid = insert_user().id

      player_results = %{
        valid => result_for(:north_south, :north_south, :north),
        "dev_host" => result_for(:east_west, :north_south, :east)
      }

      assert {:ok, _} = Profiles.apply_completed_game(player_results, :north_south)

      assert {:ok, %{wins: 1}} = Profiles.get_or_create_profile(valid)
      assert Repo.aggregate(PlayerProfile, :count) == 1
    end

    test "matches a user whose id arrives in upper case" do
      user = insert_user()
      player_results = %{String.upcase(user.id) => result_for(:north_south, :north_south, :north)}

      assert {:ok, _} = Profiles.apply_completed_game(player_results, :north_south)

      assert %PlayerProfile{wins: 1} = Repo.get_by(PlayerProfile, user_id: user.id)
    end
  end

  describe "win% edge cases" do
    test "0 games -> 0.0" do
      user_id = Ecto.UUID.generate()
      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.win_rate == 0.0
    end

    test "all wins -> 1.0" do
      user_id = Ecto.UUID.generate()
      {:ok, profile} = Profiles.get_or_create_profile(user_id)
      profile |> PlayerProfile.changeset(%{games_played: 3, wins: 3}) |> Repo.update!()

      assert {:ok, view} = Profiles.get_profile_for_screen(user_id)
      assert view.win_rate == 1.0
    end
  end

  describe "rebuild_from_history/1" do
    defp save_game(room_code, winner, user_ids, results) do
      {:ok, _} =
        Stats.save_game_result(%{
          room_code: room_code,
          winner: winner,
          final_scores: %{north_south: 62, east_west: 45},
          bid_amount: 8,
          bid_team: :north_south,
          duration_seconds: 300,
          completed_at: DateTime.utc_now(),
          player_ids: user_ids,
          player_results: results
        })
    end

    test "reproduces the same counters as incremental application (DB round-trip)" do
      u1 = insert_user().id
      u2 = insert_user().id

      results1 = %{
        u1 => result_for(:north_south, :north_south, :north),
        u2 => result_for(:east_west, :north_south, :east)
      }

      results2 = %{
        u1 => result_for(:north_south, :east_west, :north),
        u2 => result_for(:east_west, :east_west, :east)
      }

      # Incremental
      assert {:ok, _} = Profiles.apply_completed_game(results1, :north_south)
      assert {:ok, _} = Profiles.apply_completed_game(results2, :east_west)

      {:ok, inc_u1} = Profiles.get_or_create_profile(u1)
      {:ok, inc_u2} = Profiles.get_or_create_profile(u2)

      # Persist the same games (string-keyed JSONB after round-trip)
      save_game("ROOMA", :north_south, [u1, u2], results1)
      save_game("ROOMB", :east_west, [u1, u2], results2)

      assert {:ok, reb_u1} = Profiles.rebuild_from_history(u1)
      assert {:ok, reb_u2} = Profiles.rebuild_from_history(u2)

      assert {reb_u1.games_played, reb_u1.wins, reb_u1.losses} ==
               {inc_u1.games_played, inc_u1.wins, inc_u1.losses}

      assert {reb_u2.games_played, reb_u2.wins, reb_u2.losses} ==
               {inc_u2.games_played, inc_u2.wins, inc_u2.losses}

      assert {reb_u1.games_played, reb_u1.wins} == {2, 1}
    end

    test "is idempotent (running twice yields identical counters)" do
      u1 = Ecto.UUID.generate()

      save_game("ROOMC", :north_south, [u1], %{
        u1 => result_for(:north_south, :north_south, :north)
      })

      assert {:ok, first} = Profiles.rebuild_from_history(u1)
      assert {:ok, second} = Profiles.rebuild_from_history(u1)

      assert {first.games_played, first.wins, first.losses} ==
               {second.games_played, second.wins, second.losses}
    end

    test "overwrites drifted counters" do
      u1 = Ecto.UUID.generate()

      save_game("ROOMD", :north_south, [u1], %{
        u1 => result_for(:north_south, :north_south, :north)
      })

      {:ok, profile} = Profiles.get_or_create_profile(u1)
      profile |> PlayerProfile.changeset(%{games_played: 99, wins: 99}) |> Repo.update!()

      assert {:ok, rebuilt} = Profiles.rebuild_from_history(u1)
      assert rebuilt.games_played == 1
      assert rebuilt.wins == 1
      assert rebuilt.losses == 0
    end

    test "tolerates a historical row with nil player_results via position fallback" do
      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()

      # player_results nil; position derived from order in player_ids:
      # index 0 -> :north (north_south), index 1 -> :east (east_west)
      save_game("ROOME", :north_south, [u1, u2], nil)

      assert {:ok, reb_u1} = Profiles.rebuild_from_history(u1)
      assert {:ok, reb_u2} = Profiles.rebuild_from_history(u2)

      assert reb_u1.games_played == 1
      assert reb_u1.wins == 1
      assert reb_u2.wins == 0
      assert reb_u2.losses == 1
    end
  end

  describe "rebuild_all/0" do
    test "rebuilds every user appearing in player_ids and returns the count" do
      u1 = insert_user().id
      u2 = insert_user().id
      u3 = insert_user().id

      {:ok, _} =
        Stats.save_game_result(%{
          room_code: "ROOMF",
          winner: :north_south,
          completed_at: DateTime.utc_now(),
          duration_seconds: 100,
          player_ids: [u1, u2],
          player_results: %{
            u1 => result_for(:north_south, :north_south, :north),
            u2 => result_for(:east_west, :north_south, :east)
          }
        })

      {:ok, _} =
        Stats.save_game_result(%{
          room_code: "ROOMG",
          winner: :east_west,
          completed_at: DateTime.utc_now(),
          duration_seconds: 100,
          player_ids: [u3],
          player_results: %{u3 => result_for(:east_west, :east_west, :east)}
        })

      assert {:ok, 3} = Profiles.rebuild_all()

      assert {:ok, %{wins: 1}} = Profiles.get_or_create_profile(u1)
      assert {:ok, %{losses: 1}} = Profiles.get_or_create_profile(u2)
      assert {:ok, %{wins: 1}} = Profiles.get_or_create_profile(u3)
    end

    test "creates no row for a deleted player" do
      kept = insert_user().id
      deleted = insert_user()

      {:ok, _} =
        Stats.save_game_result(%{
          room_code: "ROOMH",
          winner: :north_south,
          completed_at: DateTime.utc_now(),
          duration_seconds: 100,
          player_ids: [kept, deleted.id],
          player_results: %{
            kept => result_for(:north_south, :north_south, :north),
            deleted.id => result_for(:east_west, :north_south, :east)
          }
        })

      Repo.delete!(deleted)

      assert {:ok, 1} = Profiles.rebuild_all()
      assert %PlayerProfile{wins: 1} = Repo.get_by(PlayerProfile, user_id: kept)
      assert is_nil(Repo.get_by(PlayerProfile, user_id: deleted.id))
    end
  end

  describe "achievement awards (PID-50)" do
    test "award_achievement/4 inserts a row and returns :awarded; a duplicate returns :already" do
      user_id = Ecto.UUID.generate()

      assert :awarded = Profiles.award_achievement(user_id, :player, 1, %{count: 10})
      assert :already = Profiles.award_achievement(user_id, :player, 1, %{count: 12})

      # No duplicate row — the unique index holds.
      assert Repo.aggregate(
               from(a in Achievement, where: a.user_id == ^user_id),
               :count
             ) == 1
    end

    test "ensure_achievements/2 returns only the newly-inserted keys; re-running returns []" do
      user_id = Ecto.UUID.generate()

      awards = [{:player, 1, %{}}, {:winner, 1, %{}}]
      assert Enum.sort(Profiles.ensure_achievements(user_id, awards)) == [:player, :winner]
      assert Profiles.ensure_achievements(user_id, awards) == []
    end

    test "permanence: an earned row is never removed or downgraded" do
      user_id = Ecto.UUID.generate()
      assert :awarded = Profiles.award_achievement(user_id, :winstreak, 1, %{streak: 3})

      # A rebuild over an empty history recomputes sub-threshold counts but must
      # not remove the row (no delete/downgrade path exists).
      assert {:ok, _} = Profiles.rebuild_from_history(user_id)

      assert [%Achievement{achievement_key: "winstreak", tier: 1}] =
               Profiles.list_achievements(user_id)
    end

    test "list_achievements/1 returns only the user's own rows" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      assert :awarded = Profiles.award_achievement(a, :player)
      assert :awarded = Profiles.award_achievement(b, :winner)

      assert Profiles.list_achievements(a) |> Enum.map(& &1.achievement_key) == ["player"]
      assert Profiles.list_achievements(b) |> Enum.map(& &1.achievement_key) == ["winner"]
    end
  end

  describe "public_profile/1 — fail-closed allowlist (PID-54)" do
    # A representative screen-shaped map; mirrors get_profile_for_screen/1's keys.
    defp screen_fixture(overrides \\ %{}) do
      Map.merge(
        %{
          user_id: Ecto.UUID.generate(),
          games_played: 42,
          wins: 25,
          losses: 17,
          win_rate: 0.595,
          rating_mu: 40.0,
          rating_sigma: 5.0,
          rating_games_count: 50,
          veteran_level: 7,
          veteran_xp: 1480,
          veteran_title: "Seasoned",
          veteran_progress: {120, 210},
          veteran_prestige: 0,
          veteran_prestige_progress: nil,
          playstyle_bidding_wins: 30,
          playstyle_bidding_attempts: 49,
          bidding_win_rate: 0.61,
          aggression_needle: 0.72,
          aggression_label: :aggressive,
          aggression_insufficient: false,
          avg_winning_bid: 9.4,
          heritage_flags: %{"founding_member" => true},
          heritage: [%{key: :founding_member, label: "Founding Member", value: true}],
          first_seen_at: DateTime.utc_now(),
          account_age_days: 217,
          achievements: [],
          achievements_catalog: []
        },
        overrides
      )
    end

    test "excludes the raw rating internals and raw accumulators" do
      public = Profiles.public_profile(screen_fixture())

      refute Map.has_key?(public, :rating_mu)
      refute Map.has_key?(public, :rating_sigma)
      refute Map.has_key?(public, :rating_games_count)
      refute Map.has_key?(public, :heritage_flags)
      refute Map.has_key?(public, :playstyle_bidding_wins)
      refute Map.has_key?(public, :playstyle_bidding_attempts)

      # Not smuggled into the skill sub-object either.
      refute Map.has_key?(public.skill, :rating_mu)
      refute Map.has_key?(public.skill, :rating_sigma)
      refute Map.has_key?(public.skill, :rating_games_count)
    end

    test "classifies a rated, low-sigma rating into a non-provisional tier" do
      public =
        screen_fixture(%{rating_mu: 40.0, rating_sigma: 5.0, rating_games_count: 50})
        |> Profiles.public_profile()

      assert public.skill == %{tier: :gold, provisional: false}
    end

    test "classifies a never-rated (count 0) profile as provisional" do
      # A never-rated profile carries the default high sigma (8.333), so it is
      # provisional on both gates (count < min AND sigma >= max_sigma).
      public =
        screen_fixture(%{rating_games_count: 0, rating_sigma: 8.333})
        |> Profiles.public_profile()

      assert public.skill == %{tier: :provisional, provisional: true}
    end

    test "carries the display fields through unchanged" do
      screen = screen_fixture()
      public = Profiles.public_profile(screen)

      assert public.user_id == screen.user_id
      assert public.games_played == screen.games_played
      assert public.wins == screen.wins
      assert public.losses == screen.losses
      assert public.win_rate == screen.win_rate
      assert public.first_seen_at == screen.first_seen_at
      assert public.account_age_days == screen.account_age_days

      # progress is a {into, span} tuple in the screen map, JSON-encoded as a
      # 2-element list in the public payload.
      assert public.veteran == %{
               level: screen.veteran_level,
               xp: screen.veteran_xp,
               title: screen.veteran_title,
               progress: [120, 210],
               prestige: 0,
               prestige_progress: nil
             }

      assert public.heritage == screen.heritage

      assert public.playstyle == %{
               bidding_win_rate: screen.bidding_win_rate,
               aggression_needle: screen.aggression_needle,
               aggression_label: screen.aggression_label,
               aggression_insufficient: screen.aggression_insufficient,
               avg_winning_bid: screen.avg_winning_bid
             }

      assert public.achievements == screen.achievements
      assert public.achievements_catalog == screen.achievements_catalog
    end

    test "surfaces prestige + encoded prestige_progress past the L100 cap" do
      screen =
        screen_fixture(%{
          veteran_level: 100,
          veteran_xp: 1_300_000,
          veteran_progress: :max,
          veteran_prestige: 1,
          veteran_prestige_progress: {0, 500_000}
        })

      public = Profiles.public_profile(screen)

      assert public.veteran.prestige == 1
      assert public.veteran.prestige_progress == [0, 500_000]
      assert public.veteran.progress == "max"
    end

    test "accepts a user_id and reuses get_profile_for_screen/1 internally" do
      user = insert_user()

      public = Profiles.public_profile(user.id)

      assert public.user_id == user.id
      assert public.skill == %{tier: :provisional, provisional: true}
      refute Map.has_key?(public, :rating_mu)
    end
  end

  describe "summaries_for/1" do
    test "returns level + classified tier per existing profile in one map" do
      veteran = insert_user()
      rookie = insert_user()

      {:ok, _} = Profiles.import_legacy_progression(veteran.id, %{xp: 5000})
      {:ok, _} = Profiles.get_or_create_profile(rookie.id)

      summaries = Profiles.summaries_for([veteran.id, rookie.id])

      veteran_summary = summaries[veteran.id]
      assert veteran_summary.veteran_level == Progression.level_for_xp(5000)
      # Fresh import leaves skill at default + count 0 → provisional.
      assert veteran_summary.tier == :provisional
      assert veteran_summary.provisional == true
      # A Classic import marks the profile, so the seat shows the Classic pin.
      assert veteran_summary.pin == "classic"

      assert summaries[rookie.id] == %{
               veteran_level: 1,
               prestige: 0,
               tier: :provisional,
               provisional: true,
               pin: nil
             }
    end

    test "omits users without a profile row" do
      missing_id = Ecto.UUID.generate()

      assert Profiles.summaries_for([missing_id]) == %{}
    end

    test "returns an empty map for an empty list" do
      assert Profiles.summaries_for([]) == %{}
    end
  end

  describe "xp_periods/2 (PID-198)" do
    # Each case is a fresh player: the XP rows earned at those times, the moment
    # the periods are read, and the expected sum.
    test "a week runs from Monday 00:00 to Sunday 24:00 UTC" do
      for {earned, now, this_week} <- [
            # Monday 00:00 and the last second of Sunday are the same week.
            {[{~U[2026-10-05 00:00:00Z], 1}, {~U[2026-10-11 23:59:59Z], 2}],
             ~U[2026-10-11 23:59:59Z], 3},
            # At Monday 00:00 the Sunday game belongs to last week.
            {[{~U[2026-10-11 23:59:59Z], 2}, {~U[2026-10-12 00:00:00Z], 4}],
             ~U[2026-10-12 00:00:00Z], 4}
          ] do
        user = insert_user()
        for {at, xp} <- earned, do: earn_xp(user.id, xp, at)

        assert Profiles.xp_periods(user.id, now).this_week == this_week
      end
    end

    test "a month is the calendar month in UTC" do
      for {earned, now, this_month} <- [
            {[{~U[2026-09-01 00:00:00Z], 1}, {~U[2026-09-30 23:59:59Z], 2}],
             ~U[2026-09-30 23:59:59Z], 3},
            {[{~U[2026-09-30 23:59:59Z], 2}, {~U[2026-10-01 00:00:00Z], 4}],
             ~U[2026-10-01 00:00:00Z], 4}
          ] do
        user = insert_user()
        for {at, xp} <- earned, do: earn_xp(user.id, xp, at)

        assert Profiles.xp_periods(user.id, now).this_month == this_month
      end
    end

    test "only the player's own rows count, and no rows sum to zero" do
      user = insert_user()
      other = insert_user()
      earn_xp(other.id, 50, ~U[2026-10-12 10:00:00Z])

      assert Profiles.xp_periods(user.id, ~U[2026-10-14 12:00:00Z]) ==
               %{this_week: 0, this_month: 0}
    end
  end

  defp earn_xp(user_id, xp, at) do
    {:ok, game} =
      Stats.save_game_result(%{room_code: "XP", completed_at: at, player_ids: [user_id]})

    Repo.insert!(%GameXp{user_id: user_id, game_stats_id: game.id, xp: xp, earned_at: at})
  end
end
