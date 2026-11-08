defmodule PidroServer.Games.RoomStoreTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.Room.{Config, Seat}
  alias PidroServer.Games.RoomManager.Room
  alias PidroServer.Games.RoomStore

  test "a room survives the round trip through JSON, without its runtime fields" do
    now = ~U[2026-11-04 18:30:15.123456Z]
    host = Ecto.UUID.generate()
    friend = Ecto.UUID.generate()
    gone = Ecto.UUID.generate()

    {:ok, config} =
      Config.new(
        name: "Friday table",
        bot_difficulty: :smart,
        rule_set: :louisiana,
        seat_requirements: %{south: 100},
        seat_holds: %{west: friend},
        password_seats: [:south],
        seat_password: "4711"
      )

    substitute = %Seat{
      position: :east,
      occupant_type: :bot,
      bot_pid: self(),
      status: :bot_substitute,
      disconnected_at: now,
      grace_expires_at: DateTime.add(now, 100, :second),
      reserved_for: gone,
      decision_id: "decision-1",
      reason: "heartbeat_timeout",
      network: "cellular",
      app_version: "3.3.0",
      app_build: "14",
      round_trips: [42, 200, 18]
    }

    substitute =
      substitute |> Seat.start_connection_stats(1000) |> Seat.record_connection_reply(237)

    substitute = %{substitute | round_trips: [42, 200, 18]}

    room = %Room{
      id: Ecto.UUID.generate(),
      code: "AB12",
      host_id: host,
      status: :playing,
      max_players: 4,
      created_at: now,
      last_activity: now,
      config: config,
      pace: :own,
      seat_hold_started_at: %{west: now},
      locked: true,
      kicked_ids: ["kicked-1"],
      invite_live_until: now,
      positions: %{north: host, east: gone, south: "bot_AB12_south", west: nil},
      spectator_ids: ["watcher"],
      phase_timers: %{east: make_ref()},
      seats: %{
        north: Seat.new_human(:north, host, is_owner: true, joined_at: now),
        east: substitute,
        south: Seat.new_bot(:south, self(), "antti"),
        west: Seat.new_vacant(:west)
      },
      bot_personas: ["antti", "marcel"],
      auto_played_turns: [
        {{{"instance-not-an-atom", 42}, gone},
         %{type: :play_card, card: %{rank: 14, suit: :hearts}}}
      ],
      consecutive_timeouts: %{north: 2},
      turn_pause_budget: %{key: {:seat, :east, :playing, 42}, remaining_ms: 9_000},
      table_outcome: %{
        turns: 21,
        bot_turns: 4,
        peers: [host],
        left: [gone],
        participants: %{
          host => %{platform: "android", app_version: "3.3.0", app_build: "11"},
          gone => %{platform: "ios", app_version: "3.2.3"}
        }
      },
      last_hand_number: 3,
      game: %{hand: 3, scores: %{north_south: 12, east_west: -4}},
      ready_epoch: 5,
      snapshot_revision: 17,
      ready_player_ids: MapSet.new([host]),
      seat_lifecycle_revision: 9,
      game_number: 2,
      game_started_at: now,
      post_game_summaries: %{},
      talk: [%{user_id: host, seat: :north, text: "gg"}],
      bot_talk: %{
        seen: {"instance-1", 42},
        said: [{"antti", "line_teasing_hello_1"}, {"gun", "coin_heart"}],
        hand: ["coin_heart"],
        shown_until: 0,
        phase: nil,
        turn: nil
      }
    }

    json = room |> RoomStore.encode() |> Jason.encode!() |> Jason.decode!()
    refute json |> Jason.encode!() |> String.contains?("#PID")

    seats = Map.new(room.seats, fn {position, seat} -> {position, %{seat | bot_pid: nil}} end)

    assert RoomStore.decode(json) == %{
             room
             | seats: seats,
               phase_timers: %{},
               turn_timer: nil,
               talk: [],
               bot_talk: %{room.bot_talk | seen: nil},
               game: nil
           }
  end

  test "a post-game summary comes back as the JSON the app is sent" do
    summary = %{xp: %{gained: 40}, tier: :gold, title: "Dealer"}
    room = %Room{code: "CD34", status: :finished, post_game_summaries: %{"user-1" => summary}}

    json = room |> RoomStore.encode() |> Jason.encode!() |> Jason.decode!()

    assert RoomStore.decode(json).post_game_summaries ==
             %{"user-1" => summary |> Jason.encode!() |> Jason.decode!()}
  end
end
