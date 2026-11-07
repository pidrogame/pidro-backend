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

  test "today: external review holds iPhone players on 3.2.1, not internal 3.2.4", %{
    stores: stores,
    minimums: minimums
  } do
    assert [%{text: text, action: nil}] = StoreBuilds.next_steps(stores, minimums, [])
    assert text =~ "3.2.4 is waiting for Apple's review"
    assert text =~ "Players are on 3.2.1"
    assert stores["ios"].data.newest.number == "10"
    assert stores["ios"].data.live.number == "7"
    assert stores["android"].data.live.number == "9"

    assert Enum.any?(
             stores["android"].data.tracks,
             &(&1.track == "production" and &1.state == "draft")
           )
  end

  test "Team-only tells the admin to add Friends and submit", %{
    stores: stores,
    minimums: minimums
  } do
    stores = put_in(stores, ["ios", :data, :newest, :friends], false)
    assert [%{text: text}] = StoreBuilds.next_steps(stores, minimums, [])

    assert text ==
             "iPhone: 3.2.4 (10) is only in the Team group. Add it to Friends and submit it for review."
  end

  test "live above minimum suggests News with both live versions, never the pending build", %{
    stores: stores
  } do
    counts = [
      %{platform: "android", version: "3.2.3", count: 12},
      %{platform: "ios", version: "3.2.0", count: 7}
    ]

    steps = StoreBuilds.next_steps(stores, %{"ios" => "3.2.1", "android" => "3.2.3"}, counts)
    assert [%{action: nil}, %{action: :news, text: text}] = steps
    assert text =~ "Android 3.2.4 is live, but players below it aren't nudged"
    assert text =~ "12 player-version records"

    assert StoreBuilds.live_versions(stores) == %{
             "show_below_android" => "3.2.4",
             "show_below_ios" => "3.2.1"
           }
  end

  test "all good at equal minimums, even with a leftover production draft", %{
    stores: stores,
    minimums: minimums
  } do
    stores = put_in(stores, ["ios", :data, :newest], stores["ios"].data.live)
    assert StoreBuilds.next_steps(stores, minimums, []) == [%{text: "All good", action: nil}]

    assert [%{action: :news}] =
             StoreBuilds.next_steps(stores, Map.delete(minimums, "android"), [])

    assert [%{text: text}] =
             StoreBuilds.next_steps(stores, %{minimums | "android" => "3.2.10"}, [])

    assert text =~ "minimum 3.2.10 is above the live version 3.2.4"
    refute StoreBuilds.above?("not a version", "3.2.4")
  end

  test "missing credentials and failed reads cannot say all good or suggest publishing", %{
    stores: stores,
    minimums: minimums
  } do
    stores = put_in(stores, ["ios", :error], :not_connected)
    stores = put_in(stores, ["android", :error], "Store request failed (HTTP 403). Try Refresh.")
    assert [ios, android] = StoreBuilds.next_steps(stores, minimums, [])
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
    assert [%{text: text}] = StoreBuilds.next_steps(stores, minimums, [])
    assert text =~ "3.2.1 (10)"
    refute text =~ "over-the-air"
  end

  test "unknown live version preserves the other platform's existing minimum", %{
    stores: stores,
    minimums: minimums
  } do
    stores = put_in(stores, ["android", :data, :live, :version], nil)

    assert Enum.any?(
             StoreBuilds.next_steps(stores, minimums, []),
             &String.contains?(&1.text, "live release name is not an app version")
           )

    assert StoreBuilds.live_versions(stores, minimums)["show_below_android"] == "3.2.4"
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
             %{platform: "android", version: "3.2.3", count: 2},
             %{platform: "android", version: "3.2.4", count: 1},
             %{platform: "ios", version: "3.2.1", count: 1}
           ]
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
    assert Map.delete(policy, :source) == News.native_update_policy()
  end
end
