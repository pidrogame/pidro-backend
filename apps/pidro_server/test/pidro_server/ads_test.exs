defmodule PidroServer.AdsTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.{AccountsFixtures, Ads, Profiles, Settings}
  alias PidroServer.Ads.Event
  alias PidroServer.Entitlements.Entitlement
  alias PidroServer.Profiles.PlayerProfile

  @no_ads %{eligible: false, next_game_needs_ad: false, games_until_ad: 0, free_games_left: 0}

  setup do
    Settings.put(:ads_enabled, true)
    :ok
  end

  # An adult with `games` finished games and `solo` solo games started.
  defp player(age_band \\ "18_plus", games, solo) do
    user = AccountsFixtures.user_fixture() |> change(age_band: age_band) |> Repo.update!()
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    profile |> change(games_played: games, solo_games_started: solo) |> Repo.update!()
    user
  end

  defp profile(user), do: Repo.get_by!(PlayerProfile, user_id: user.id)

  defp set_solo(user, solo) do
    Repo.update_all(from(p in PlayerProfile, where: p.user_id == ^user.id),
      set: [solo_games_started: solo]
    )
  end

  defp start_solo_game(user) do
    :ok = Profiles.count_solo_start(user.id)
    await_tasks()
  end

  defp events(user), do: Repo.all(from e in Event, where: e.user_id == ^user.id, select: e.kind)

  defp expire_credit(user, seconds_ago) do
    Repo.update_all(from(p in PlayerProfile, where: p.user_id == ^user.id),
      set: [ad_credit_expires_at: DateTime.add(DateTime.utc_now(), -seconds_ago)]
    )
  end

  describe "decision/1" do
    test "a free adult past the free games, before the 3rd solo start, needs an ad" do
      assert Ads.decision(player(10, 2)) ==
               %{eligible: true, next_game_needs_ad: true, games_until_ad: 0, free_games_left: 0}

      assert Ads.decision(player(10, 3)) ==
               %{eligible: true, next_game_needs_ad: false, games_until_ad: 2, free_games_left: 0}

      assert %{eligible: true, next_game_needs_ad: false, free_games_left: 1} =
               Ads.decision(player(9, 2))
    end

    test "Classic games count toward the free games" do
      user = player(0, 2)
      flags = %{"played_pidro_one" => true, "games_played_counter" => 10}

      Repo.update_all(from(p in PlayerProfile, where: p.user_id == ^user.id),
        set: [heritage_flags: flags]
      )

      assert Ads.decision(user).next_game_needs_ad
    end

    test "the kill switch makes everyone ineligible" do
      user = player(10, 2)
      Settings.put(:ads_enabled, false)
      assert Ads.decision(user) == @no_ads
    end

    test "only adults are eligible" do
      assert Ads.decision(player("13_17", 10, 2)) == @no_ads
      assert Ads.decision(player("unknown", 10, 2)) == @no_ads
    end

    test "a premium player is never eligible; a lapsed one is again" do
      user = player(10, 2)

      entitlement =
        Repo.insert!(%Entitlement{
          user_id: user.id,
          entitlement: "premium",
          active: true,
          source: "store"
        })

      assert Ads.decision(user) == @no_ads
      assert :ok = Ads.admit_solo_room(user)

      entitlement |> change(active: false) |> Repo.update!()
      assert Ads.decision(user).next_game_needs_ad
    end

    test "a player with no profile yet starts with all the free games left" do
      user = AccountsFixtures.user_fixture() |> change(age_band: "18_plus") |> Repo.update!()

      assert Ads.decision(user) ==
               %{
                 eligible: true,
                 next_game_needs_ad: false,
                 games_until_ad: 11,
                 free_games_left: 10
               }
    end

    test "reads the admin values on each call" do
      user = player(10, 2)
      assert Ads.decision(user).next_game_needs_ad
      Settings.put(:ads_free_games, 11)
      refute Ads.decision(user).next_game_needs_ad
    end
  end

  describe "offer/2" do
    test "counts one offer per needed game, however often it is read" do
      user = player(10, 2)
      for _ <- 1..3, do: assert(Ads.offer(user, true).next_game_needs_ad)
      assert events(user) == ["offered"]

      Repo.update_all(from(p in PlayerProfile, where: p.user_id == ^user.id),
        inc: [solo_games_started: 3]
      )

      assert Ads.offer(user, true).next_game_needs_ad
      assert events(user) == ["offered", "offered"]
    end

    test "counts nothing for a client that cannot show ads, but tells it the same" do
      user = player(10, 2)
      assert Ads.offer(user, false).next_game_needs_ad
      assert events(user) == []
    end

    test "counts nothing when no ad is needed or the player is not eligible" do
      assert Ads.offer(player(10, 3), true).eligible
      assert Ads.offer(player("13_17", 10, 2), true) == @no_ads
      assert Repo.aggregate(Event, :count) == 0
    end
  end

  describe "admit_solo_room/1 and the credit" do
    test "without a credit a needed ad answers ad_required with the decision, and counts the offer" do
      user = player(10, 2)

      assert {:error, {:ad_required, %{next_game_needs_ad: true, eligible: true}}} =
               Ads.admit_solo_room(user)

      assert events(user) == ["offered"]
    end

    test "a watched ad admits solo rooms until a solo game starts, then the next ad is due" do
      user = player(10, 2)
      assert :ok = Ads.report(user, :watched)
      # A retried create, or one that failed, needs no second ad.
      assert :ok = Ads.admit_solo_room(user)
      assert :ok = Ads.admit_solo_room(user)

      start_solo_game(user)
      assert profile(user).ad_credit_expires_at == nil
      set_solo(user, 5)
      assert {:error, {:ad_required, _}} = Ads.admit_solo_room(user)
    end

    test "an unavailable ad gives the same credit, counted apart" do
      user = player(10, 2)
      assert :ok = Ads.report(user, :unavailable)
      assert :ok = Ads.admit_solo_room(user)
      assert Enum.sort(events(user)) == ["unavailable"]
    end

    test "a credit lasts ten minutes" do
      user = player(10, 2)
      Ads.report(user, :watched)
      expire_credit(user, -5)
      assert :ok = Ads.admit_solo_room(user)

      Ads.report(user, :watched)
      expire_credit(user, 1)
      assert {:error, {:ad_required, _}} = Ads.admit_solo_room(user)

      Ads.report(user, :watched)

      [expires_at] =
        Repo.all(
          from p in PlayerProfile, where: p.user_id == ^user.id, select: p.ad_credit_expires_at
        )

      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 600, 2
    end

    test "a solo game's start uses up the credit even when no ad was needed" do
      user = player(10, 0)
      Ads.report(user, :watched)
      start_solo_game(user)
      assert profile(user).solo_games_started == 1
      set_solo(user, 2)
      assert {:error, {:ad_required, _}} = Ads.admit_solo_room(user)
    end

    test "nobody is held back while ads are off" do
      user = player(10, 2)
      Settings.put(:ads_enabled, false)
      assert :ok = Ads.admit_solo_room(user)
      assert events(user) == []
    end

    test "a dismissed offer is counted and gives no credit" do
      user = player(10, 2)
      assert :ok = Ads.report(user, :dismissed)
      assert {:error, {:ad_required, _}} = Ads.admit_solo_room(user)
      assert Enum.sort(events(user)) == ["dismissed", "offered"]
    end
  end

  describe "admin numbers" do
    test "daily_counts/1 counts each kind per UTC day, 14 days, newest first" do
      user = player(10, 2)
      today = Date.utc_today()

      at = fn days_ago, kind ->
        inserted_at = DateTime.new!(Date.add(today, -days_ago), ~T[12:00:00.000000])
        Repo.insert!(%Event{user_id: user.id, kind: kind, inserted_at: inserted_at})
      end

      at.(0, "offered")
      at.(0, "offered")
      at.(0, "watched")
      at.(1, "unavailable")
      at.(13, "dismissed")
      at.(14, "offered")

      days = Ads.daily_counts(14)
      assert length(days) == 14
      assert hd(days) == %{date: today, offered: 2, watched: 1, unavailable: 0, dismissed: 0}
      assert Enum.at(days, 1).unavailable == 1

      assert List.last(days) == %{
               date: Date.add(today, -13),
               offered: 0,
               watched: 0,
               unavailable: 0,
               dismissed: 1
             }
    end

    test "adults_past_free_games/1 counts adults whose record reached the free games" do
      player(10, 0)
      player(25, 0)
      player(9, 0)
      player("13_17", 50, 0)
      player("unknown", 50, 0)
      AccountsFixtures.user_fixture() |> change(age_band: "18_plus") |> Repo.update!()
      premium = player(30, 0)

      Repo.insert!(%Entitlement{
        user_id: premium.id,
        entitlement: "premium",
        active: true,
        source: "store"
      })

      assert Ads.adults_past_free_games(Settings.ads()) == 2
      assert Ads.adults_past_free_games(%{ads_free_games: 0}) == 4
    end
  end
end
