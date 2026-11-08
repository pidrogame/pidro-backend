defmodule PidroServer.StoreBuildsTest do
  use PidroServer.DataCase, async: true
  alias PidroServer.{News, StoreBuilds}
  alias PidroServer.StoreBuilds.Client
  alias PidroServer.Stats.SeatEvent

  setup do
    fixture = File.read!(Path.expand("../fixtures/store_builds.json", __DIR__)) |> Jason.decode!()
    ios = Client.parse_asc(fixture["asc"], fixture["friends"], fixture["team"])
    android = Client.parse_play(fixture["play"])

    stores =
      Map.new([{"ios", ios}, {"android", android}], fn {platform, data} ->
        {platform, %{data: data, error: nil}}
      end)

    %{stores: stores, minimums: %{"android" => "3.2.4", "ios" => "3.2.1"}}
  end

  test "today: only Apple's review is pending, with no iOS minimum and Android minimum at live",
       %{
         stores: stores
       } do
    counts = [
      %{platform: "ios", version: "3.2.1", number: nil, count: 8},
      %{platform: "android", version: "3.2.3", number: nil, count: 3},
      %{platform: "android", version: "3.2.4", number: nil, count: 5}
    ]

    assert [%{text: text, action: nil}] =
             next_steps(stores, %{"android" => "3.2.4"}, counts)

    assert text =~ "3.2.4 (10) is waiting for Apple's review"
    assert text =~ "Players are on 3.2.1 (7)"
    assert stores["ios"].data.newest.number == "10"
    assert stores["ios"].data.live.number == "7"
    assert stores["android"].data.live.number == "9"

    assert Enum.any?(
             stores["android"].data.tracks,
             &(&1.track == "production" and &1.state == "draft")
           )
  end

  test "a nudge needs older players on that platform, not just a missing or lower minimum", %{
    stores: stores
  } do
    stores = put_in(stores, ["ios", :data, :newest], stores["ios"].data.live)

    counts = [
      %{platform: "ios", version: "3.2.1", number: nil, count: 8},
      %{platform: "android", version: "3.2.3", number: nil, count: 3},
      %{platform: "android", version: "3.2.4", number: nil, count: 5}
    ]

    for ios_minimum <- [nil, "3.2.0"] do
      assert [%{action: :news, text: text}] =
               next_steps(stores, %{"ios" => ios_minimum}, counts)

      assert text =~ "Android 3.2.4 (9) is live"
      assert text =~ "3 player-build records"
    end

    assert [
             %{
               text:
                 "Both stores have their newest build out, and older installs are nudged to update.",
               action: nil,
               tone: :good
             }
           ] =
             next_steps(stores, %{}, [])
  end

  test "review and Team-only steps take priority even when older iPhone players were seen", %{
    stores: stores
  } do
    counts = [%{platform: "ios", version: "3.2.0", number: nil, count: 7}]
    minimums = %{"android" => "3.2.4"}

    for state <- ["WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"] do
      reviewing = put_in(stores, ["ios", :data, :newest, :state], state)
      assert [%{action: nil, text: text}] = next_steps(reviewing, minimums, counts)
      assert text =~ "Apple's review"
    end

    team_only = put_in(stores, ["ios", :data, :newest, :friends], false)
    assert [%{action: nil, text: text}] = next_steps(team_only, minimums, counts)
    assert text =~ "only in the Team group"

    released = put_in(stores, ["ios", :data, :newest], stores["ios"].data.live)
    assert [%{action: :news}] = next_steps(released, minimums, counts)
  end

  test "Team-only tells the admin to add Friends and submit", %{
    stores: stores,
    minimums: minimums
  } do
    stores = put_in(stores, ["ios", :data, :newest, :friends], false)
    assert [%{text: text}] = next_steps(stores, minimums, [])

    assert text ==
             "iPhone: 3.2.4 (10) is only in the Team group. Add it to Friends and submit it for review."
  end

  test "live above minimum suggests News with both live versions, never the pending build", %{
    stores: stores
  } do
    counts = [
      %{platform: "android", version: "3.2.3", number: nil, count: 12},
      %{platform: "ios", version: "3.2.0", number: nil, count: 7}
    ]

    steps = next_steps(stores, %{"ios" => "3.2.1", "android" => "3.2.3"}, counts)
    assert [%{action: nil}, %{action: :news, text: text}] = steps
    assert text =~ "Android 3.2.4 (9) is live, but players below it aren't nudged"
    assert text =~ "12 player-build records"

    assert StoreBuilds.live_versions(stores) == %{
             "show_below_android" => "3.2.4",
             "show_below_android_build" => "9",
             "show_below_ios" => "3.2.1",
             "show_below_ios_build" => "7"
           }
  end

  test "all good at equal minimums, even with a leftover production draft", %{
    stores: stores,
    minimums: minimums
  } do
    stores = put_in(stores, ["ios", :data, :newest], stores["ios"].data.live)

    assert [
             %{
               text:
                 "Both stores have their newest build out, and older installs are nudged to update.",
               action: nil,
               tone: :good
             }
           ] =
             next_steps(stores, minimums, [])

    assert [%{action: :news}] =
             next_steps(stores, Map.delete(minimums, "android"), [
               %{platform: "android", version: "3.2.3", number: nil, count: 1}
             ])

    assert [%{text: text}] =
             next_steps(stores, %{minimums | "android" => "3.2.10"}, [])

    assert text =~ "minimum 3.2.10 is above the live build 3.2.4 (9)"
    refute StoreBuilds.above?("not a version", "3.2.4")
  end

  test "missing credentials and failed reads cannot say all good or suggest publishing", %{
    stores: stores,
    minimums: minimums
  } do
    stores = put_in(stores, ["ios", :error], :not_connected)
    stores = put_in(stores, ["android", :error], "Store request failed (HTTP 403). Try Refresh.")
    assert [ios, android] = next_steps(stores, minimums, [])
    assert ios.text == "App Store Connect not connected"
    assert android.text =~ "HTTP 403"
    assert android.text =~ "Last good data"
    assert ios.action == nil and android.action == nil
    assert Client.fetch("ios", []) == {:error, :not_connected}
    assert Client.fetch("android", []) == {:error, :not_connected}
  end

  test "same-version pending rebuild does not claim over-the-air updates are frozen", %{
    stores: stores,
    minimums: minimums
  } do
    stores = put_in(stores, ["ios", :data, :newest, :version], "3.2.1")
    assert [%{text: text}] = next_steps(stores, minimums, [])
    assert text =~ "3.2.1 (10)"
    refute text =~ "over-the-air"
  end

  test "unknown live version preserves the other platform's existing minimum", %{
    stores: stores,
    minimums: minimums
  } do
    stores = put_in(stores, ["android", :data, :live, :version], nil)

    assert Enum.any?(
             next_steps(stores, minimums, []),
             &String.contains?(&1.text, "live release name is not an app version")
           )

    assert StoreBuilds.live_versions(stores, minimums(minimums))["show_below_android"] == "3.2.4"
  end

  @now ~U[2026-11-08 08:00:00Z]
  @android_today [{"3.2.4", 9}, {"3.2.3", 26}, {"3.2.2", 15}]
  @android_later [{"3.2.4", 38}, {"3.2.3", 9}, {"3.2.2", 3}]

  defp counts(platform, list),
    do:
      for(
        {version, count} <- list,
        do: %{platform: platform, version: version, number: nil, count: count}
      )

  # Minimums as the policy gives them, a version per platform; builds are set where tested.
  defp minimums(versions),
    do: for({platform, version} <- versions, version, into: %{}, do: {platform, minimum(version)})

  defp minimum(nil), do: nil
  defp minimum(version), do: %{version: version, number: nil}

  defp next_steps(stores, versions, counts),
    do: StoreBuilds.next_steps(stores, minimums(versions), counts)

  defp card(stores, platform, minimum, counts) do
    minimum = if is_binary(minimum), do: minimum(minimum), else: minimum
    rail = StoreBuilds.rail(platform, stores[platform], minimum, counts, @now)
    players = StoreBuilds.players(platform, stores[platform], minimum, counts)

    {Enum.map(rail, &{&1.status, &1.value, &1.note}),
     Enum.map(players.segments, &{StoreBuilds.build_label(&1), &1.kind}), players.summary}
  end

  # The newest iPhone build is approved and live in Friends.
  defp approved(stores) do
    live = %{stores["ios"].data.newest | state: "IN_BETA_TESTING", friends: true}
    put_in(stores, ["ios", :data], %{stores["ios"].data | newest: live, live: live})
  end

  test "design state today: waiting on Apple, Android nudged", %{stores: stores} do
    ios = counts("ios", [{"3.2.4", 2}, {"3.2.3", 1}, {"3.2.1", 24}])
    counts = ios ++ counts("android", @android_today)
    minimums = %{"android" => "3.2.4"}

    assert [%{platform: "ios", tone: :waiting, title: "Waiting on Apple", action: nil}] =
             next_steps(stores, minimums, counts)

    assert card(stores, "ios", nil, counts) ==
             {[
                {:done, "3.2.4 (10)", "7 Nov"},
                {:now, "Waiting", "for 1 day"},
                {:todo, "Still 3.2.1 (7)", "Friends group"},
                {:todo, "Not yet", "after review"}
              ], [{"3.2.4", :newest}, {"3.2.3", :older}, {"3.2.1", :older}],
              "24 of 27 wait for Apple"}

    # Play reports no dates, so no notes are invented for them.
    assert card(stores, "android", "3.2.4", counts) ==
             {[
                {:done, "3.2.4 (9)", nil},
                {:done, "Passed", nil},
                {:done, "Live", "open testing"},
                {:done, "From 3.2.4", "store notice on"}
              ], [{"3.2.4", :newest}, {"3.2.3", :nudged}, {"3.2.2", :nudged}],
              "41 of 50 still to update"}
  end

  test "review waits from Apple's submission date, else the upload date", %{stores: stores} do
    assert {[_, {:now, "Waiting", "for 1 day"} | _], _, _} = card(stores, "ios", nil, [])

    stores = put_in(stores, ["ios", :data, :newest, :submitted_at], nil)
    assert {[_, {:now, "Waiting", "for 1 day"} | _], _, _} = card(stores, "ios", nil, [])

    stores = put_in(stores, ["ios", :data, :newest, :uploaded_at], "2026-11-05T07:00:00Z")
    stores = put_in(stores, ["ios", :data, :newest, :state], "IN_BETA_REVIEW")
    assert {[_, {:now, "In review", "for 3 days"} | _], _, _} = card(stores, "ios", nil, [])
  end

  test "nobody waits on the store while the newest build is still with us", %{stores: stores} do
    counts = counts("ios", [{"3.2.4", 2}, {"3.2.3", 1}, {"3.2.1", 24}])
    ready = put_in(stores, ["ios", :data, :newest, :state], "READY_FOR_BETA_SUBMISSION")

    assert {[_, {:now, "Not submitted", nil} | _], _, "24 of 27 can't get 3.2.4 (10) yet"} =
             card(ready, "ios", nil, counts)

    no_builds = put_in(stores, ["ios", :data, :newest], nil)

    assert {_, [{"3.2.4", :newest}, {"3.2.3", :newest}, {"3.2.1", :newest}], "all 27 up to date"} =
             card(no_builds, "ios", nil, counts)
  end

  test "design state Team only: orange, stuck at review, nobody can get it", %{stores: stores} do
    stores = approved(stores)

    team_only = %{
      stores["ios"].data.newest
      | version: "3.2.5",
        number: "11",
        uploaded_at: "2026-11-09T07:00:00Z",
        state: "READY_FOR_BETA_SUBMISSION",
        friends: false
    }

    stores = put_in(stores, ["ios", :data, :newest], team_only)
    counts = counts("ios", [{"3.2.4", 25}, {"3.2.1", 2}]) ++ counts("android", @android_later)

    assert [%{tone: :stuck, title: "iPhone 3.2.5 (11) never reached players"}] =
             next_steps(stores, %{"android" => "3.2.4", "ios" => "3.2.4"}, counts)

    assert card(stores, "ios", "3.2.4", counts) ==
             {[
                {:done, "3.2.5 (11)", "9 Nov"},
                {:stuck, "Team only", "not in Friends"},
                {:todo, "Still 3.2.4 (10)", "Friends group"},
                {:todo, "Not yet", "after review"}
              ], [{"3.2.4", :newest}, {"3.2.1", :nudged}], "nobody can get 3.2.5 (11) yet"}
  end

  test "design state nudge needed: older iPhone players are grey until a minimum is set", %{
    stores: stores
  } do
    stores = approved(stores)
    counts = counts("ios", [{"3.2.4", 6}, {"3.2.3", 1}, {"3.2.1", 20}])

    assert [%{tone: :waiting, title: "Nudge iPhone players to 3.2.4 (10)", action: :news}] =
             next_steps(stores, %{"android" => "3.2.4"}, counts)

    assert card(stores, "ios", nil, counts) ==
             {[
                {:done, "3.2.4 (10)", "7 Nov"},
                {:done, "Approved", nil},
                {:done, "Live", "Friends group"},
                {:now, "Not set", "publish a post"}
              ], [{"3.2.4", :newest}, {"3.2.3", :older}, {"3.2.1", :older}],
              "21 of 27 not nudged"}

    # A minimum below some of them nudges those and leaves the rest grey.
    assert {_, [{"3.2.4", :newest}, {"3.2.3", :older}, {"3.2.1", :nudged}], "1 of 27 not nudged"} =
             card(stores, "ios", "3.2.3", counts)
  end

  test "design state all good: emerald, every stop done", %{stores: stores} do
    stores = approved(stores)
    counts = counts("ios", [{"3.2.4", 23}, {"3.2.1", 4}]) ++ counts("android", @android_later)
    minimums = %{"android" => "3.2.4", "ios" => "3.2.4"}

    assert [%{tone: :good, title: "Everyone can get the latest", platform: nil}] =
             next_steps(stores, minimums, counts)

    assert card(stores, "ios", "3.2.4", counts) ==
             {[
                {:done, "3.2.4 (10)", "7 Nov"},
                {:done, "Approved", nil},
                {:done, "Live", "Friends group"},
                {:done, "From 3.2.4", "store notice on"}
              ], [{"3.2.4", :newest}, {"3.2.1", :nudged}], "4 of 27 still to update"}

    assert {_, _, "12 of 50 still to update"} = card(stores, "android", "3.2.4", counts)
    assert {_, [], "no players recorded"} = card(stores, "android", "3.2.4", [])
  end

  test "an unchecked store shows four grey stops and no build" do
    store = %{data: nil, error: :not_connected}
    rail = StoreBuilds.rail("android", store, nil, [], @now)
    assert Enum.map(rail, & &1.status) == [:todo, :todo, :todo, :todo]
    assert Enum.map(rail, & &1.label) == ~w(Uploaded Review Players Nudge)
  end

  test "player counts deduplicate users per version and exclude events older than seven days" do
    now = NaiveDateTime.utc_now(:second)

    for {user, platform, version, at} <- [
          {"one", "android", "3.2.3", now},
          {"one", "android", "3.2.3", now},
          {"two", "android", "3.2.3", now},
          {"one", "android", "3.2.4", now},
          {"three", "ios", "3.2.1", now},
          {"old", "ios", "3.2.1", NaiveDateTime.add(now, -8, :day)}
        ] do
      Repo.insert!(%SeatEvent{
        user_id: user,
        platform: platform,
        app_version: version,
        inserted_at: at,
        kind: "join",
        room_code: "TEST"
      })
    end

    assert StoreBuilds.player_versions() == [
             %{platform: "android", version: "3.2.3", number: nil, count: 2},
             %{platform: "android", version: "3.2.4", number: nil, count: 1},
             %{platform: "ios", version: "3.2.1", number: nil, count: 1}
           ]
  end

  # 3.3.0 ships as builds now: iOS 14 then 15, Android 11 then 12.
  defp on_330(stores, ios_newest, ios_live) do
    build = fn number, state ->
      %{stores["ios"].data.newest | version: "3.3.0", number: number, state: state, friends: true}
    end

    android = %{stores["android"].data.live | version: "3.3.0", number: "12", label: "3.3.0"}

    stores
    |> put_in(["ios", :data], %{
      stores["ios"].data
      | newest: build.(ios_newest, "WAITING_FOR_BETA_REVIEW"),
        live: build.(ios_live, "IN_BETA_TESTING")
    })
    |> put_in(["android", :data], %{stores["android"].data | newest: android, live: android})
  end

  defp build_counts(platform, list),
    do:
      for(
        {version, number, count} <- list,
        do: %{platform: platform, version: version, number: number, count: count}
      )

  test "same version, newer build in review: players wait on Apple for the build", %{
    stores: stores
  } do
    stores = on_330(stores, "15", "14")
    counts = build_counts("ios", [{"3.3.0", "14", 5}, {"3.2.4", nil, 2}])

    minimums = %{
      "ios" => %{version: "3.3.0", number: "14"},
      "android" => %{version: "3.3.0", number: "12"}
    }

    assert [%{title: "Waiting on Apple", text: text}] =
             StoreBuilds.next_steps(stores, minimums, counts)

    assert text ==
             "iPhone: 3.3.0 (15) is waiting for Apple's review. Players can install 3.3.0 (14)."

    assert {[_, {:now, "Waiting", _}, {:todo, "Still 3.3.0 (14)", _}, {:todo, "Not yet", _}],
            [{"3.3.0 (14)", :older}, {"3.2.4", :nudged}], "7 of 7 wait for Apple"} =
             card(stores, "ios", minimums["ios"], counts)
  end

  test "a version-only minimum leaves the live version's older builds un-nudged; a build nudges them",
       %{stores: stores} do
    stores = on_330(stores, "15", "15")

    counts =
      build_counts("ios", [{"3.3.0", "15", 6}, {"3.3.0", "14", 3}, {"3.3.0", nil, 1}]) ++
        build_counts("android", [{"3.3.0", "11", 4}, {"3.3.0", "12", 2}])

    version_only = %{
      "ios" => %{version: "3.3.0", number: nil},
      "android" => %{version: "3.3.0", number: "12"}
    }

    assert [%{title: "Nudge iPhone players to 3.3.0 (15)", action: :news, text: text}] =
             StoreBuilds.next_steps(stores, version_only, counts)

    assert text =~ "3 player-build records below it"

    # An app that sends no build can't be nudged by one, so it is not counted as behind.
    assert {[_, _, _, {:now, "From 3.3.0", "publish a post"}],
            [{"3.3.0 (15)", :newest}, {"3.3.0 (14)", :older}, {"3.3.0", :newest}],
            "3 of 10 not nudged"} = card(stores, "ios", version_only["ios"], counts)

    assert {[_, _, _, {:done, "From 3.3.0 (12)", "store notice on"}],
            [{"3.3.0 (12)", :newest}, {"3.3.0 (11)", :nudged}], "4 of 6 still to update"} =
             card(stores, "android", version_only["android"], counts)

    with_build = put_in(version_only, ["ios", :number], "15")
    assert [%{tone: :good}] = StoreBuilds.next_steps(stores, with_build, counts)

    assert {[_, _, _, {:done, "From 3.3.0 (15)", "store notice on"}],
            [{"3.3.0 (15)", :newest}, {"3.3.0 (14)", :nudged}, {"3.3.0", :newest}],
            "3 of 10 still to update"} = card(stores, "ios", with_build["ios"], counts)

    too_high = put_in(version_only, ["ios", :number], "16")
    assert [%{text: text}] = StoreBuilds.next_steps(stores, too_high, counts)
    assert text =~ "the minimum 3.3.0 (16) is above the live build 3.3.0 (15)"

    assert StoreBuilds.live_versions(stores) == %{
             "show_below_android" => "3.3.0",
             "show_below_android_build" => "12",
             "show_below_ios" => "3.3.0",
             "show_below_ios_build" => "15"
           }
  end

  test "player counts keep the builds of one version apart" do
    now = NaiveDateTime.utc_now(:second)

    for {user, build} <- [{"one", "14"}, {"two", "14"}, {"three", "15"}, {"old-app", nil}] do
      Repo.insert!(%SeatEvent{
        user_id: user,
        platform: "ios",
        app_version: "3.3.0",
        app_build: build,
        inserted_at: now,
        kind: "join",
        room_code: "TEST"
      })
    end

    assert StoreBuilds.player_versions() == [
             %{platform: "ios", version: "3.3.0", number: "14", count: 2},
             %{platform: "ios", version: "3.3.0", number: "15", count: 1},
             %{platform: "ios", version: "3.3.0", number: nil, count: 1}
           ]
  end

  test "minimums pair each policy version with its build" do
    assert StoreBuilds.minimums(%{
             minimum_native_versions: %{"android" => "3.3.0", "ios" => "3.3.0"},
             minimum_native_builds: %{"ios" => "15"}
           }) == %{
             "android" => %{version: "3.3.0", number: nil},
             "ios" => %{version: "3.3.0", number: "15"}
           }
  end

  test "policy source follows the same post and its empty platform, not a config fallback" do
    {:ok, post} =
      News.create(%{
        title_en: "New in 3.2.4",
        body_en: "Update",
        app_update: true,
        show_below_android: "3.2.4"
      })

    {:ok, _} = News.publish(post)
    policy = News.native_update_policy_with_source()
    assert policy.source =~ "New in 3.2.4"
    assert policy.minimum_native_versions == %{"android" => "3.2.4"}
    assert policy.minimum_native_builds == %{}
    assert Map.delete(policy, :source) == News.native_update_policy()
  end
end
