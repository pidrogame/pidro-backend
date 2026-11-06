defmodule PidroServer.Stats.ConnectionStrengthTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Stats

  test "complete table accounting includes bids, passes and cards but not other events" do
    game = %{
      events: [
        {:bid_made, :north, 7},
        {:player_passed, :east},
        {:card_played, :south, {14, :hearts}},
        {:trump_declared, :north, :hearts}
      ]
    }

    assert Stats.TableOutcome.complete?(%{turns: 3}, game)
    refute Stats.TableOutcome.complete?(%{turns: 2}, game)
    refute Stats.TableOutcome.complete?(%{turns: 4}, game)
    refute Stats.TableOutcome.complete?(nil, game)
  end

  test "table outcome shares weight turns, exclude games without peers, and separate windows and versions" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    for {turns, bot, finished, version, days} <- [
          {20, 5, true, "3.2.4", 0},
          {80, 15, false, "3.2.4", 0},
          {50, 10, nil, "3.2.4", 0},
          {10, 10, true, "3.2.4", 8},
          {10, 9, false, "3.2.3", 0},
          {100, 100, false, "3.2.4", 31}
        ] do
      :ok =
        Stats.record_table_outcome(%{
          game_instance_id: Ecto.UUID.generate(),
          turns: turns,
          bot_turns: bot,
          others_finished: finished,
          cohorts: [%{platform: "android", app_version: version}],
          inserted_at: NaiveDateTime.add(now, -days, :day)
        })
    end

    await_tasks()
    assert [old, current] = Stats.connection_analytics(7)
    assert old.bot_turn_percent == 90
    assert current.bot_turn_percent == 20
    assert current.others_finished_percent == 50
    assert current.takeover_games == 2
    assert [_, month] = Stats.connection_analytics(30)
    assert month.bot_turn_percent == 25
    assert_in_delta month.others_finished_percent, 200 / 3, 0.001
  end

  test "connection grades require ten minutes and both latency and drop thresholds" do
    grade = fn seconds, median, drops ->
      Stats.connection_grade(%{duration_seconds: seconds, median_ms: median, drops: drops})
    end

    assert grade.(599, 30, 0) == :insufficient
    assert grade.(600, 30, 0) == :good
    assert grade.(3600, nil, 0) == :insufficient
    assert grade.(3600, 149, 0) == :good
    assert grade.(3600, 150, 0) == :fair
    assert grade.(3600, 30, 1) == :fair
    assert grade.(3600, 399, 3) == :fair
    assert grade.(3600, 400, 0) == :poor
    assert grade.(3600, 30, 4) == :poor
    assert grade.(7200, 30, 1) == :good
  end

  test "seven-day summary pools RTT samples and weights network by duration" do
    rows = [
      %{
        duration_seconds: 2400,
        drops: 6,
        rtt_histogram: %{"420" => 17, "2000" => 2},
        network_ms: %{"cellular" => 2_400_000},
        app_version: "3.2.4",
        platform: "android"
      },
      %{
        duration_seconds: 1200,
        drops: 0,
        rtt_histogram: %{"100" => 1},
        network_ms: %{"wifi" => 1_200_000}
      }
    ]

    summary = Stats.summarize_connections(rows)
    assert summary.median_ms == 420
    assert summary.p95_ms == 2000
    assert summary.drops_per_hour == 6
    assert summary.network == "cellular"
    assert summary.grade == :poor
    assert summary.app_version == "3.2.4"
    assert Stats.summarize_connections([]).grade == :insufficient

    unknown = %{duration_seconds: 3600, drops: 0, rtt_histogram: %{}}
    short = %{duration_seconds: 590, drops: 1, rtt_histogram: %{"30" => 20}}
    assert Stats.summarize_connections([short, unknown]).grade == :insufficient
    measured = Stats.summarize_connections([%{short | duration_seconds: 610}, unknown])
    assert measured.grade == :poor
    assert measured.measured_seconds == 610
    assert measured.unknown_seconds == 3600
  end

  test "analytics weights play time, keeps unknown data visible and separates builds and windows" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    for {user, seconds, histogram, version, at} <- [
          {"good", 3600, %{"30" => 100}, "3.2.4", now},
          {"poor", 10_800, %{"420" => 100}, "3.2.4", now},
          {"unknown", 3600, %{}, "3.2.4", now},
          {"older", 3600, %{"30" => 100}, "3.2.4", NaiveDateTime.add(now, -8, :day)},
          {"other-build", 3600, %{"30" => 100}, "3.2.3", now}
        ] do
      Repo.insert!(%PidroServer.Stats.ConnectionGame{
        user_id: user,
        room_id: Ecto.UUID.generate(),
        room_code: "CONN",
        game_instance_id: Ecto.UUID.generate(),
        checks_sent: 100,
        unanswered_checks: 0,
        drops: 0,
        duration_seconds: seconds / 1,
        disconnected_seconds: 0.0,
        rtt_histogram: histogram,
        app_version: version,
        platform: "android",
        inserted_at: at,
        updated_at: at
      })
    end

    assert [%{app_version: "3.2.3"} = other, current] = Stats.connection_analytics(7)
    assert other.poor_percent == 0
    assert current.duration_seconds == 18_000
    assert current.poor_percent == 60
    assert current.unknown_percent == 20
    assert [_, month] = Stats.connection_analytics(30)
    assert month.poor_percent == 50
    assert Stats.connection_games("older") == []
    assert [_] = Stats.connection_games("older", 30)

    unknown = Repo.one!(from c in PidroServer.Stats.ConnectionGame, where: c.user_id == "unknown")

    Repo.insert!(%{
      unknown
      | id: Ecto.UUID.generate(),
        user_id: "poor",
        game_instance_id: Ecto.UUID.generate()
    })

    assert [_, mixed] = Stats.connection_analytics(7)
    assert mixed.poor_percent == 50
    assert_in_delta mixed.unknown_percent, 33.333333, 0.00001
  end
end
