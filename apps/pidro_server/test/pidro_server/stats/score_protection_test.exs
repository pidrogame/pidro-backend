defmodule PidroServer.Stats.ScoreProtectionTest do
  @moduledoc """
  Tests for score recording with disconnected and substitute players.
  """

  use PidroServer.DataCase, async: false

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Games.RoomManager
  alias PidroServer.Profiles.{GameXp, PlayerProfile}
  alias PidroServer.RoomManagerCase
  alias PidroServer.Stats
  alias PidroServer.Stats.{AbandonmentEvent, GameStats}

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

  describe "build_player_results/3" do
    test "records all connected humans as played with correct winners" do
      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: Seat.new_human(:south, "user2"),
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      assert map_size(results) == 4
      assert results["user1"].participation == :played
      assert results["user2"].result == :win
      assert results["user3"].result == :loss
      assert results["user4"].position == :west
    end

    test "records abandoned humans when the substitute bot still carries reserved_for" do
      bot_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, bot_seat} =
        Seat.new_human(:south, "user2")
        |> Seat.disconnect()
        |> then(fn {:ok, seat} -> Seat.start_grace(seat, DateTime.utc_now()) end)
        |> then(fn {:ok, seat} -> Seat.substitute_bot(seat, bot_pid) end)

      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: bot_seat,
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      results = Stats.build_player_results(seats, :north_south)

      assert results["user2"].participation == :abandoned
      assert results["user2"].result == :win

      Process.exit(bot_pid, :kill)
    end

    test "merges permanent bot abandonments back into player results" do
      bot_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, bot_seat} =
        Seat.new_human(:south, "user2")
        |> Seat.disconnect()
        |> then(fn {:ok, seat} -> Seat.start_grace(seat, DateTime.utc_now()) end)
        |> then(fn {:ok, seat} -> Seat.substitute_bot(seat, bot_pid) end)
        |> then(fn {:ok, seat} -> Seat.make_permanent_bot(seat) end)

      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: bot_seat,
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      abandonment_events = [
        %AbandonmentEvent{user_id: "user2", room_code: "ROOM1", position: "south"}
      ]

      results = Stats.build_player_results(seats, :north_south, abandonment_events)

      assert map_size(results) == 4
      assert results["user2"].participation == :abandoned
      assert results["user2"].position == :south

      Process.exit(bot_pid, :kill)
    end

    test "records both the original abandoned player and the substitute human" do
      seats = %{
        north: Seat.new_human(:north, "user1"),
        south: %Seat{
          position: :south,
          occupant_type: :human,
          user_id: "substitute1",
          status: :connected,
          substitute: true
        },
        east: Seat.new_human(:east, "user3"),
        west: Seat.new_human(:west, "user4")
      }

      abandonment_events = [%{user_id: "user2", position: "south"}]
      results = Stats.build_player_results(seats, :north_south, abandonment_events)

      assert map_size(results) == 5
      assert results["user2"].participation == :abandoned
      assert results["substitute1"].participation == :substitute
      assert results["substitute1"].result == :win
    end
  end

  describe "record_abandonment/3" do
    test "persists one abandonment event per user and room" do
      assert :ok = Stats.record_abandonment("user123", "ABC123", :north)
      assert :ok = Stats.record_abandonment("user123", "ABC123", :north)

      events = Stats.list_abandonments_for_room("ABC123")

      assert length(events) == 1
      assert hd(events).user_id == "user123"
      assert hd(events).position == "north"
    end

    test "completed bot games only persist human player ids" do
      host_id = AccountsFixtures.user_fixture().id
      bot_east = "bot_BOTS_east"
      bot_south = "bot_BOTS_south"
      bot_west = "bot_BOTS_west"

      seats = %{
        north: Seat.new_human(:north, host_id),
        east: %Seat{
          position: :east,
          occupant_type: :human,
          user_id: bot_east,
          status: :connected,
          substitute: true
        },
        south: %Seat{
          position: :south,
          occupant_type: :human,
          user_id: bot_south,
          status: :connected,
          substitute: true
        },
        west: %Seat{
          position: :west,
          occupant_type: :human,
          user_id: bot_west,
          status: :connected,
          substitute: true
        }
      }

      room = %{
        code: "BOTS",
        created_at: DateTime.utc_now(),
        seats: seats
      }

      assert {:ok, %{^host_id => _summary}} =
               Stats.save_completed_game(room, :north_south, %{
                 north_south: 66,
                 east_west: -7
               })

      saved_game = Repo.get_by!(GameStats, room_code: "BOTS")

      assert saved_game.player_ids == [host_id]
      assert Map.has_key?(saved_game.player_results, host_id)
      refute Map.has_key?(saved_game.player_results, bot_east)
      refute Map.has_key?(saved_game.player_results, bot_south)
      refute Map.has_key?(saved_game.player_results, bot_west)
    end

    test "user stats exposes abandonment metrics" do
      user_id = Ecto.UUID.generate()

      {:ok, _game_stats} =
        Stats.save_game_result(%{
          room_code: "ROOM1",
          winner: :north_south,
          final_scores: %{north_south: 62, east_west: 45},
          bid_amount: 8,
          bid_team: :north_south,
          duration_seconds: 300,
          completed_at: DateTime.utc_now(),
          player_ids: [user_id],
          player_results: %{
            user_id => %{
              participation: :played,
              result: :win,
              team: :north_south,
              position: :north
            }
          }
        })

      assert :ok = Stats.record_abandonment(user_id, "ROOM1", :north)

      stats = Stats.get_user_stats(user_id)

      assert stats.games_played == 1
      assert stats.games_abandoned == 1
      assert stats.abandonment_rate == 1.0
      assert %DateTime{} = stats.last_abandoned_at
    end
  end

  describe "completed game persistence" do
    test "explicit leave during grace records abandonment once and keeps the earned result" do
      [host, leaver, south, west] = Enum.map(1..4, fn _ -> Ecto.UUID.generate() end)
      {:ok, room} = RoomManager.create_room(host, %{})

      for user_id <- [leaver, south, west],
          do: assert({:ok, _, _} = RoomManager.join_room(room.code, user_id))

      PidroServer.RoomFixtures.ready_room(room.code)
      {:ok, playing_room} = RoomManager.get_room(room.code)
      position = position_for(playing_room, leaver)
      :ok = RoomManager.handle_player_disconnect(room.code, leaver)
      {:ok, before_leave} = RoomManagerCase.expire_phase(room.code, position, :phase2_start)
      bot_pid = before_leave.seats[position].bot_pid

      assert :ok = RoomManager.leave_room(leaver)
      assert {:error, :not_in_room} = RoomManager.leave_room(leaver)

      send(
        RoomManager,
        {:timeout, before_leave.phase_timers[position], {:phase3_gone, room.code, position}}
      )

      {:ok, after_leave} = RoomManager.get_room(room.code)
      assert after_leave.seats[position].bot_pid == bot_pid
      position_name = Atom.to_string(position)

      assert [%{user_id: ^leaver, position: ^position_name}] =
               Stats.list_abandonments_for_room(room.code)

      winning_team = if position in [:north, :south], do: :north_south, else: :east_west
      scores = Map.put(%{north_south: 40, east_west: 40}, winning_team, 62)
      send(RoomManager, {:game_over, room.code, winning_team, scores})
      saved = wait_until(fn -> Repo.get_by(GameStats, room_code: room.code) end)
      assert saved.player_results[leaver]["participation"] == "abandoned"
      assert saved.player_results[leaver]["result"] == "win"
      assert Enum.sort(saved.player_ids) == Enum.sort([host, leaver, south, west])
    end

    test "persists original players and substitutes exactly once on game_over" do
      user1 = Ecto.UUID.generate()
      user2 = Ecto.UUID.generate()
      user3 = Ecto.UUID.generate()
      user4 = Ecto.UUID.generate()
      substitute = Ecto.UUID.generate()

      {:ok, room} = RoomManager.create_room(user1, %{name: "Score Protection"})
      {:ok, _, _} = RoomManager.join_room(room.code, user2)
      {:ok, _, _} = RoomManager.join_room(room.code, user3)
      {:ok, _, _} = RoomManager.join_room(room.code, user4)
      PidroServer.RoomFixtures.ready_room(room.code)

      {:ok, playing_room} = RoomManager.get_room(room.code)
      position = position_for(playing_room, user2)

      :ok = RoomManager.handle_player_disconnect(room.code, user2)
      {:ok, _} = RoomManagerCase.expire_phase(room.code, position, :phase2_start)
      {:ok, _} = RoomManagerCase.expire_phase(room.code, position, :phase3_gone)
      {:ok, _} = RoomManager.open_seat(room.code, position, user1)
      {:ok, _, ^position} = RoomManager.join_as_substitute(room.code, substitute)

      game_over = {:game_over, room.code, :north_south, %{north_south: 62, east_west: 45}}
      send(GenServer.whereis(RoomManager), game_over)
      send(GenServer.whereis(RoomManager), game_over)

      saved_game =
        wait_until(fn ->
          Repo.get_by(GameStats, room_code: room.code)
        end)

      assert saved_game.winner == "north_south"
      assert map_size(saved_game.player_results) == 5
      assert saved_game.player_results[user2]["participation"] == "abandoned"
      assert saved_game.player_results[substitute]["participation"] == "substitute"

      assert Enum.sort(saved_game.player_ids) ==
               Enum.sort([user1, user2, user3, user4, substitute])

      assert Repo.aggregate(GameStats, :count) == 1
    end

    test "leaving a solo bot game leaves no abandonment and no counted game" do
      player = AccountsFixtures.user_fixture()
      room = bot_table(player.id, [], [:east, :south, :west], %{solo: true})

      assert :ok = RoomManager.leave_room(player.id)

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
      assert Stats.list_abandonments_for_room(room.code) == []
      assert Repo.get_by(GameStats, room_code: room.code) == nil
      assert_uncounted(player.id)
    end

    test "leaving a live room of bots leaves no abandonment and no counted game" do
      player = AccountsFixtures.user_fixture()
      room = bot_table(player.id, [], [:east, :south, :west])

      assert :ok = RoomManager.leave_room(player.id)
      assert Stats.list_abandonments_for_room(room.code) == []

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
      refute Repo.get_by(PidroServer.Stats.GameStats, room_code: room.code)
      assert_uncounted(player.id)
    end

    test "leaving a live room with another human still records the abandonment" do
      [host, guest] = for _ <- 1..2, do: AccountsFixtures.user_fixture()
      room = bot_table(host.id, [guest.id], [:south, :west])

      assert :ok = RoomManager.leave_room(guest.id)
      assert [%{user_id: guest_id}] = Stats.list_abandonments_for_room(room.code)
      assert guest_id == guest.id

      saved = finish(room.code)
      assert saved.player_results[guest.id]["participation"] == "abandoned"
      assert Stats.get_user_stats(guest.id).games_abandoned == 1
      assert Repo.get_by(PlayerProfile, user_id: guest.id).games_played == 1
    end

    test "a bot holding a disconnected human's seat counts as that human" do
      [host, guest] = for _ <- 1..2, do: AccountsFixtures.user_fixture()
      room = bot_table(host.id, [guest.id], [:south, :west])

      :ok = RoomManager.handle_player_disconnect(room.code, guest.id)
      {:ok, held} = RoomManagerCase.expire_phase(room.code, :east, :phase2_start)
      assert %Seat{occupant_type: :bot, reserved_for: reserved_for} = held.seats.east
      assert reserved_for == guest.id

      assert :ok = RoomManager.leave_room(host.id)
      assert [%{user_id: host_id}] = Stats.list_abandonments_for_room(room.code)
      assert host_id == host.id
    end

    test "pre-start abandonment does not record a game or abandonment" do
      {:ok, room} = RoomManager.create_room("user1", %{name: "Waiting Room"})
      {:ok, _, _} = RoomManager.join_room(room.code, "user2")

      assert :ok = RoomManager.leave_room("user2")

      assert Stats.list_abandonments_for_room(room.code) == []
      assert Repo.get_by(GameStats, room_code: room.code) == nil
    end
  end

  # A live table: the host north, guests from east, bots on `bot_positions`.
  defp bot_table(host_id, guest_ids, bot_positions, config \\ %{}) do
    {:ok, room} = RoomManager.create_room(host_id, config)
    for guest <- guest_ids, do: {:ok, _, _} = RoomManager.join_room(room.code, guest)

    for position <- bot_positions,
        do:
          {:ok, _, ^position} =
            RoomManager.join_bot(room.code, "bot_#{position}", self(), position)

    PidroServer.RoomFixtures.ready_room(room.code)
    {:ok, %{status: :playing} = room} = RoomManager.get_room(room.code)
    room
  end

  defp finish(room_code) do
    send(RoomManager, {:game_over, room_code, :east_west, %{north_south: 30, east_west: 62}})
    wait_until(fn -> Repo.get_by(GameStats, room_code: room_code) end)
  end

  # Nothing that counts against the player: no abandonment, no game in their
  # stats or the leaderboard, no profile counters, no XP for a league.
  defp assert_uncounted(user_id) do
    stats = Stats.get_user_stats(user_id)
    assert {stats.games_played, stats.games_abandoned, stats.abandonment_rate} == {0, 0, 0.0}
    refute Enum.any?(Stats.get_leaderboard(limit: 100), &(&1.player_id == user_id))

    refute Repo.exists?(
             from p in PlayerProfile, where: p.user_id == ^user_id and p.games_played > 0
           )

    refute Repo.exists?(from x in GameXp, where: x.user_id == ^user_id)
  end

  defp position_for(room, user_id) do
    Enum.find_value(room.seats, fn {pos, seat} ->
      if seat.user_id == user_id, do: pos
    end)
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(_fun, 0) do
    flunk("timed out waiting for condition")
  end

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
