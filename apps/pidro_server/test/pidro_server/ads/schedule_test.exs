defmodule PidroServer.Ads.ScheduleTest do
  use ExUnit.Case, async: true

  alias PidroServer.Ads.Schedule

  @settings %{
    ads_enabled: true,
    ads_free_games: 10,
    ads_early_every_n: 3,
    ads_games_until_steady: 40,
    ads_steady_every_n: 2
  }

  describe "needs_ad?/3 with 10 / 3 / 40 / 2" do
    test "the first 10 finished games are free: game 10 has no ad, game 11 can" do
      # The 3rd solo start would need one; 9 finished games means it is game 10.
      refute Schedule.needs_ad?(@settings, 9, 2)
      assert Schedule.needs_ad?(@settings, 10, 2)
      refute Schedule.needs_ad?(@settings, 0, 2)
    end

    test "every 3rd solo start needs one: the 3rd and the 6th, not the ones around them" do
      assert [1, 2, 3, 4, 5, 6, 7] |> Enum.map(&Schedule.needs_ad?(@settings, 50, &1 - 1)) ==
               [false, false, true, false, false, true, false]
    end

    test "the 39th start is still early, the 40th is early and has none" do
      assert Schedule.needs_ad?(@settings, 50, 38)
      # 39 started: 39 < 40, so every 3rd; 40 is no multiple of 3.
      refute Schedule.needs_ad?(@settings, 50, 39)
    end

    test "from 40 solo starts every 2nd: the 41st has none, the 42nd and 44th do" do
      refute Schedule.needs_ad?(@settings, 50, 40)
      assert Schedule.needs_ad?(@settings, 50, 41)
      refute Schedule.needs_ad?(@settings, 50, 42)
      # 44 is no multiple of 3: only the steady cadence asks for it.
      assert Schedule.needs_ad?(@settings, 50, 43)
    end

    test "the free games count finished games, not solo starts" do
      # 300 games at tables with people, no solo start yet.
      refute Schedule.needs_ad?(@settings, 300, 0)
      assert Schedule.needs_ad?(@settings, 300, 2)
    end
  end

  describe "games_until_ad/3" do
    test "is 0 when the next solo game needs an ad" do
      assert Schedule.games_until_ad(@settings, 10, 2) == 0
      assert Schedule.games_until_ad(@settings, 50, 41) == 0
    end

    test "counts the solo games that start before the one with the ad" do
      assert Schedule.games_until_ad(@settings, 10, 3) == 2
      assert Schedule.games_until_ad(@settings, 50, 39) == 2
      assert Schedule.games_until_ad(@settings, 50, 40) == 1
    end

    test "for a new player runs through the free games first" do
      # Game 11 is the 11th solo start, no multiple of 3; the 12th is.
      assert Schedule.games_until_ad(@settings, 0, 0) == 11
      # The 3rd solo start is the first game past the free ones.
      assert Schedule.games_until_ad(@settings, 8, 0) == 2
    end
  end

  test "a huge free-games value answers at once" do
    settings = %{@settings | ads_free_games: 10_000_000}
    {micros, games} = :timer.tc(fn -> Schedule.games_until_ad(settings, 0, 0) end)
    # Past the free games the 10_000_001st solo start is odd; the 10_000_002nd has the ad.
    assert games == 10_000_001
    assert micros < 50_000
  end

  test "an every_n of 1 asks before every solo game past the free ones" do
    settings = %{@settings | ads_early_every_n: 1, ads_free_games: 0}
    assert Enum.all?(0..39, &Schedule.needs_ad?(settings, &1, &1))
  end
end
