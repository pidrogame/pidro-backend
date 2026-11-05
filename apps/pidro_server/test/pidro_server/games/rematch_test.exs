defmodule PidroServer.Games.RematchTest do
  @moduledoc """
  A rematch is a new game in the same room: same code, same seats, agreed
  through the ready check once the previous game is over.
  """

  use PidroServerWeb.ChannelCase, async: false

  import Ecto.Query

  alias PidroServer.AccountsFixtures
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.{GameAdapter, GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Profiles
  alias PidroServer.Repo
  alias PidroServer.RoomFixtures
  alias PidroServer.Stats.GameStats
  alias PidroServerWeb.GameChannel

  @scores %{north_south: 62, east_west: 40}

  setup do
    RoomManager.reset_for_test()
    on_exit(&PidroServer.RoomManagerCase.cleanup/0)
    :ok
  end

  defp four_player_game(config \\ %{}) do
    users = Enum.map(1..4, &AccountsFixtures.user_fixture(%{display_name: "Rematch #{&1}"}))
    [host | others] = users
    {:ok, room} = RoomManager.create_room(host.id, Map.merge(%{name: "Thursday four"}, config))
    for user <- others, do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
    playing = RoomFixtures.ready_room(room.code)
    assert playing.status == :playing
    {playing, Enum.map(users, & &1.id)}
  end

  defp finish_game(room_code) do
    send(RoomManager, {:game_over, room_code, :north_south, @scores})
    {:ok, finished} = RoomManager.get_room(room_code)
    assert finished.status == :finished
    finished
  end

  defp ask_for_rematch(room, user_ids) do
    {:ok, %{ready_epoch: epoch}} = RoomManager.readiness(room.code)

    Enum.map(user_ids, fn user_id ->
      {:ok, snapshot} = RoomManager.confirm_rematch(room.code, room.id, user_id, self(), epoch)
      snapshot
    end)
  end

  defp bot_processes do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(PidroServer.Games.Bots.BotSupervisor),
        is_pid(pid),
        do: pid
  end

  defp game_pid(room_code) do
    {:ok, pid} = GameSupervisor.get_game(room_code)
    pid
  end

  describe "the same four, again" do
    test "a rematch waiting for a replacement retains the hold until that friend sits" do
      {room, [host, departing | remaining]} = four_player_game()
      finish_game(room.code)
      :ok = RoomManager.leave_room(departing)
      friend = AccountsFixtures.user_fixture()
      {:ok, held} = RoomManager.set_seat_hold(room.code, host, :east, friend.id)
      assert held.config.seat_holds == %{east: friend.id}
      {:ok, snapshot} = RoomManager.readiness(room.code)
      assert snapshot.seats.east.held_for.user_id == friend.id

      assert {:error, :table_not_full, _} =
               RoomManager.confirm_ready(room.code, room.id, host, self(), snapshot.ready_epoch)

      assert {:error, :seat_taken} = RoomManager.join_room(room.code, departing, :east)
      {:ok, joined, :east} = RoomManager.join_room(room.code, friend.id)
      assert joined.config.seat_holds == %{}
      :ok = RoomManager.register_game_channel(room.code, friend.id, self())
      {:ok, snapshot} = RoomManager.readiness(room.code)

      for user <- [host, friend.id | remaining] do
        assert {:ok, _} =
                 RoomManager.confirm_ready(room.code, room.id, user, self(), snapshot.ready_epoch)
      end

      {:ok, rematch} = RoomManager.get_room(room.code)
      assert rematch.status == :playing
      assert rematch.game_number == 2
      assert rematch.positions.east == friend.id
      assert rematch.config == joined.config
    end

    test "rematch retains requirements without checking existing players or substitutes" do
      users = Enum.map(1..4, fn _ -> AccountsFixtures.user_fixture() end)
      [host, partner | others] = users
      {:ok, _} = Profiles.import_legacy_progression(partner, %{legacy_played_games: 100})
      {:ok, room} = RoomManager.create_room(host.id, %{seat_requirements: %{south: 100}})
      {:ok, _, :south} = RoomManager.join_room(room.code, partner.id, :south)
      for user <- others, do: {:ok, _, _} = RoomManager.join_room(room.code, user.id)
      RoomFixtures.ready_room(room.code)
      :ok = RoomManager.leave_room(partner.id)
      {:ok, _} = RoomManager.open_seat(room.code, :south, host.id)
      substitute = AccountsFixtures.user_fixture()
      assert {:ok, _, :south} = RoomManager.join_room(room.code, substitute.id)
      :ok = RoomManager.register_game_channel(room.code, substitute.id, self())

      finish_game(room.code)
      ask_for_rematch(room, Enum.map([host, substitute | others], & &1.id))
      {:ok, rematch} = RoomManager.get_room(room.code)
      assert rematch.status == :playing
      assert rematch.config.seat_requirements == %{south: 100}
      {:ok, snapshot} = RoomManager.readiness(room.code)
      assert snapshot.seats.south.min_games == 0
    end

    test "game over turns the ready check into a rematch vote" do
      {room, user_ids} = four_player_game()
      {:ok, before} = RoomManager.readiness(room.code)

      finish_game(room.code)

      {:ok, vote} = RoomManager.readiness(room.code)
      assert vote.status == :finished
      assert vote.ready_players == []
      assert vote.ready_epoch == before.ready_epoch + 1

      assert {:error, :stale_readiness, _} =
               RoomManager.confirm_rematch(
                 room.code,
                 room.id,
                 hd(user_ids),
                 self(),
                 before.ready_epoch
               )
    end

    test "the last agreement starts a new game in the same room with the same seats" do
      {room, user_ids} = four_player_game()
      first_game = game_pid(room.code)

      played =
        1
        |> Pidro.Test.DeterministicGame.opening()
        |> Pidro.Test.DeterministicGame.play_until(&(&1.hand_number == 2))

      :ok = GenServer.call(first_game, {:set_state, played})
      assert {:ok, %{hand_history: [_]}} = GameAdapter.get_state(room.code)
      finish_game(room.code)

      {early, [last]} = Enum.split(user_ids, 3)
      ask_for_rematch(room, early)

      {:ok, waiting} = RoomManager.get_room(room.code)
      assert waiting.status == :finished
      assert Process.alive?(first_game)

      [started] = ask_for_rematch(room, [last])
      assert started.status == :playing
      assert started.game == %{hand: 1, scores: %{north_south: 0, east_west: 0}}

      {:ok, rematch} = RoomManager.get_room(room.code)
      assert rematch.code == room.code
      assert rematch.id == room.id
      assert rematch.positions == room.positions
      assert rematch.host_id == room.host_id
      assert rematch.game_number == 2

      for {position, seat} <- room.seats do
        assert rematch.seats[position].user_id == seat.user_id
        assert rematch.seats[position].status == :connected
      end

      second_game = game_pid(room.code)
      refute second_game == first_game
      refute Process.alive?(first_game)

      {:ok, state} = GameAdapter.get_state(room.code)
      assert state.phase == :dealer_selection
      assert state.cumulative_scores == %{north_south: 0, east_west: 0}
      assert state.winner == nil
      assert state.hand_history == []
    end

    test "nobody is moved out of the room, so a second rematch works the same way" do
      {room, user_ids} = four_player_game()

      finish_game(room.code)
      ask_for_rematch(room, user_ids)
      finish_game(room.code)
      ask_for_rematch(room, user_ids)

      {:ok, third} = RoomManager.get_room(room.code)
      assert third.status == :playing
      assert third.game_number == 3
    end

    test "each game in the room saves its own stats and progression" do
      {room, user_ids} = four_player_game()

      finish_game(room.code)
      ask_for_rematch(room, user_ids)
      finish_game(room.code)

      rows = Repo.all(from gs in GameStats, where: gs.room_code == ^room.code)
      assert length(rows) == 2

      instance_ids = Enum.map(rows, & &1.game_instance_id)
      assert Enum.all?(instance_ids, &is_binary/1)
      assert length(Enum.uniq(instance_ids)) == 2

      for user_id <- user_ids do
        assert {:ok, %{games_played: 2}} = Profiles.get_or_create_profile(user_id)
      end
    end

    test "a repeated game over saves nothing new and leaves the rematch vote alone" do
      {room, user_ids} = four_player_game()

      finish_game(room.code)
      [vote] = ask_for_rematch(room, [hd(user_ids)])
      finish_game(room.code)

      assert Repo.aggregate(from(gs in GameStats, where: gs.room_code == ^room.code), :count) == 1
      assert {:ok, ^vote} = RoomManager.readiness(room.code)
    end
  end

  describe "who can ask, and when" do
    test "a rematch needs a finished game, and ready still needs a waiting room" do
      {room, [user_id | _]} = four_player_game()
      {:ok, %{ready_epoch: epoch}} = RoomManager.readiness(room.code)

      assert {:error, :room_not_finished, _} =
               RoomManager.confirm_rematch(room.code, room.id, user_id, self(), epoch)

      {:ok, still_playing} = RoomManager.get_room(room.code)
      assert still_playing.status == :playing
      assert still_playing.game_number == 1

      finish_game(room.code)
      {:ok, %{ready_epoch: vote_epoch}} = RoomManager.readiness(room.code)

      assert {:error, :room_not_waiting, _} =
               RoomManager.confirm_ready(room.code, room.id, user_id, self(), vote_epoch)
    end

    test "three of four is not a rematch" do
      {room, user_ids} = four_player_game()
      finish_game(room.code)

      snapshots = ask_for_rematch(room, Enum.take(user_ids, 3))

      assert List.last(snapshots).status == :finished
      assert length(List.last(snapshots).ready_players) == 3
      assert {:ok, %{status: :finished, game_number: 1}} = RoomManager.get_room(room.code)
    end
  end

  describe "a player leaves after the game" do
    test "the seat opens and the room carries on as a waiting table" do
      {room, [host, leaver | _] = user_ids} = four_player_game()
      first_game = game_pid(room.code)
      finish_game(room.code)
      {:ok, vote} = RoomManager.readiness(room.code)
      leaver_position = Enum.find_value(room.positions, fn {pos, id} -> id == leaver && pos end)

      assert :ok = RoomManager.leave_room(leaver)

      {:ok, reopened} = RoomManager.get_room(room.code)
      assert reopened.status == :waiting
      assert reopened.id == room.id
      assert reopened.host_id == host
      assert reopened.seats[leaver_position].occupant_type == :vacant
      assert reopened.ready_epoch > vote.ready_epoch

      for user_id <- user_ids -- [leaver] do
        assert Enum.any?(reopened.seats, fn {_pos, seat} -> seat.user_id == user_id end)
      end

      # The finished game goes with the vote: the next start is a new game.
      refute Process.alive?(first_game)
    end

    test "a new player takes the seat and the next game is a fresh one with its own stats" do
      {room, [_host, leaver | _] = user_ids} = four_player_game()
      finish_game(room.code)
      :ok = RoomManager.leave_room(leaver)

      newcomer = AccountsFixtures.user_fixture(%{display_name: "Newcomer"})
      assert {:ok, _room, _position} = RoomManager.join_room(room.code, newcomer.id)

      playing = RoomFixtures.ready_room(room.code)
      assert playing.status == :playing
      assert playing.game_number == 2

      {:ok, state} = GameAdapter.get_state(room.code)
      assert state.phase == :dealer_selection
      assert state.cumulative_scores == %{north_south: 0, east_west: 0}

      finish_game(room.code)
      assert Repo.aggregate(from(gs in GameStats, where: gs.room_code == ^room.code), :count) == 2
      assert {:ok, %{games_played: 1}} = Profiles.get_or_create_profile(newcomer.id)
      assert {:ok, %{games_played: 1}} = Profiles.get_or_create_profile(leaver)
      assert {:ok, %{games_played: 2}} = Profiles.get_or_create_profile(hd(user_ids))
    end

    test "a bot takes the seat and the three who stayed play on" do
      {room, [_host, leaver | _] = user_ids} = four_player_game()
      finish_game(room.code)
      leaver_position = Enum.find_value(room.positions, fn {pos, id} -> id == leaver && pos end)
      :ok = RoomManager.leave_room(leaver)

      {:ok, bot} = BotManager.start_bot(room.code, leaver_position, room.config.bot_difficulty)

      playing = RoomFixtures.ready_room(room.code)
      assert playing.status == :playing
      assert playing.game_number == 2
      assert %{occupant_type: :bot, bot_pid: ^bot} = playing.seats[leaver_position]

      for user_id <- user_ids -- [leaver] do
        assert Enum.any?(playing.seats, fn {_pos, seat} -> seat.user_id == user_id end)
      end
    end

    test "a host who leaves hands the table on instead of closing it" do
      {room, [host, partner_or_other | _]} = four_player_game()
      finish_game(room.code)

      assert :ok = RoomManager.leave_room(host)

      {:ok, reopened} = RoomManager.get_room(room.code)
      assert reopened.status == :waiting
      refute reopened.host_id == host
      assert reopened.host_id in Map.values(reopened.positions)
      assert Enum.count(reopened.seats, fn {_pos, seat} -> seat.is_owner end) == 1
      assert is_binary(partner_or_other)
    end

    test "the last one out closes the room" do
      {room, user_ids} = four_player_game()
      finish_game(room.code)

      for user_id <- user_ids, do: RoomManager.leave_room(user_id)

      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "a player who drops and stays away is treated as having left" do
      {room, [_host, absent | _]} = four_player_game()
      finish_game(room.code)

      # `ready_room/2` registered this test process as everybody's channel.
      RoomManager.unregister_game_channel(room.code, absent, self())
      {:ok, still_finished} = RoomManager.get_room(room.code)
      assert still_finished.status == :finished

      Process.sleep(Lifecycle.config(:hiccup_timeout_ms) + 100)

      {:ok, reopened} = RoomManager.get_room(room.code)
      assert reopened.status == :waiting
      refute absent in Map.values(reopened.positions)
    end

    for departure <- [:leave, :absence] do
      test "a finished host absence still hands on a table reopened by another player's #{departure}" do
        {room, [host, departing | remaining]} = four_player_game()
        finish_game(room.code)

        if unquote(departure) == :absence do
          RoomManager.unregister_game_channel(room.code, departing, self())
          Process.sleep(10)
        end

        RoomManager.unregister_game_channel(room.code, host, self())
        if unquote(departure) == :leave, do: RoomManager.leave_room(departing)
        Process.sleep(Lifecycle.config(:hiccup_timeout_ms) + 100)

        assert {:ok, reopened} = RoomManager.get_room(room.code)
        assert reopened.status == :waiting
        assert reopened.host_id in remaining

        assert Enum.sort(Enum.reject(Map.values(reopened.positions), &is_nil/1)) ==
                 Enum.sort(remaining)

        assert Enum.count(reopened.seats, fn {_, seat} -> seat.is_owner end) == 1
      end
    end

    test "the host leaves while the other player's socket is mid-reconnect: the table stays" do
      host = AccountsFixtures.user_fixture(%{display_name: "Host"})
      guest = AccountsFixtures.user_fixture(%{display_name: "Guest"})
      {:ok, room} = RoomManager.create_room(host.id, %{name: "Two and two"})
      {:ok, _room, _pos} = RoomManager.join_room(room.code, guest.id)
      {:ok, seated} = RoomManager.get_room(room.code)

      for position <- [:north, :east, :south, :west],
          seated.seats[position].occupant_type == :vacant do
        {:ok, _pid} = BotManager.start_bot(room.code, position, :basic, 5_000)
      end

      assert RoomFixtures.ready_room(room.code).status == :playing

      # The guest's socket drops during play and is still down when the game
      # ends and the host walks away.
      RoomManager.unregister_game_channel(room.code, guest.id, self())
      finish_game(room.code)
      assert :ok = RoomManager.leave_room(host.id)

      {:ok, reopened} = RoomManager.get_room(room.code)
      assert reopened.status == :waiting
      assert guest.id in Map.values(reopened.positions)

      # Back within the window: the seat is theirs and so is the table.
      :ok = RoomManager.register_game_channel(room.code, guest.id, self())
      {:ok, returned} = RoomManager.handle_player_reconnect(room.code, guest.id)
      assert returned.host_id == guest.id
      assert Enum.count(returned.seats, fn {_pos, seat} -> seat.is_owner end) == 1
    end

    test "a player already away when the game ends gets the window, then counts as gone" do
      {room, [_host, away | _]} = four_player_game()
      RoomManager.unregister_game_channel(room.code, away, self())
      finish_game(room.code)

      Process.sleep(Lifecycle.config(:hiccup_timeout_ms) + 100)

      {:ok, reopened} = RoomManager.get_room(room.code)
      assert reopened.status == :waiting
      refute away in Map.values(reopened.positions)
    end

    test "a player whose seat a substitute already took gets the same window" do
      {room, [_host, away | _]} = four_player_game()
      position = Enum.find_value(room.positions, fn {pos, id} -> id == away && pos end)

      RoomManager.unregister_game_channel(room.code, away, self())
      {:ok, hiccup} = RoomManager.get_room(room.code)

      send(
        RoomManager,
        {:timeout, hiccup.phase_timers[position], {:phase2_start, room.code, position}}
      )

      {:ok, grace} = RoomManager.get_room(room.code)
      assert %{status: :bot_substitute, reserved_for: ^away, user_id: nil} = grace.seats[position]

      finish_game(room.code)
      bots_before = bot_processes()
      Process.sleep(Lifecycle.config(:hiccup_timeout_ms) + 100)

      {:ok, reopened} = RoomManager.get_room(room.code)
      assert reopened.status == :waiting
      refute away in Map.values(reopened.positions)
      assert reopened.seats[position].occupant_type == :vacant

      # Reviving substitutes for the next game must not start one for the seat
      # that is being vacated: nothing would ever stop it.
      assert bot_processes() -- bots_before == []
    end

    test "an earlier absence cannot cut a later one short" do
      {room, [_host, flaky | _]} = four_player_game()
      finish_game(room.code)
      hiccup = Lifecycle.config(:hiccup_timeout_ms)

      RoomManager.unregister_game_channel(room.code, flaky, self())
      :ok = RoomManager.register_game_channel(room.code, flaky, self())
      Process.sleep(div(hiccup, 2))
      RoomManager.unregister_game_channel(room.code, flaky, self())

      # The first absence's timer fires now; the second absence is half over.
      Process.sleep(div(hiccup, 2) + 30)
      assert {:ok, %{status: :finished}} = RoomManager.get_room(room.code)

      Process.sleep(hiccup)
      assert {:ok, %{status: :waiting}} = RoomManager.get_room(room.code)
    end

    test "a host who was already away when the game ended still hands the table on" do
      {room, [host | _]} = four_player_game()
      :ok = RoomManager.handle_player_disconnect(room.code, host)
      finish_game(room.code)

      assert :ok = RoomManager.leave_room(host)

      {:ok, reopened} = RoomManager.get_room(room.code)
      assert reopened.status == :waiting
      assert reopened.host_id in Map.values(reopened.positions)
      refute reopened.host_id == host
      assert Enum.count(reopened.seats, fn {_pos, seat} -> seat.is_owner end) == 1
    end

    test "a player who drops and comes back in time keeps the seat and the vote" do
      {room, [_host, blip | _]} = four_player_game()
      finish_game(room.code)

      RoomManager.unregister_game_channel(room.code, blip, self())
      :ok = RoomManager.register_game_channel(room.code, blip, self())
      Process.sleep(Lifecycle.config(:hiccup_timeout_ms) + 100)

      assert {:ok, %{status: :finished}} = RoomManager.get_room(room.code)
    end
  end

  test "legacy random rooms use the rulebook for substitutes before and after rematch" do
    {room, [host | remaining]} = four_player_game(%{bot_difficulty: :random})
    position = Enum.find_value(room.positions, fn {pos, user} -> if user == host, do: pos end)
    :ok = RoomManager.handle_player_disconnect(room.code, host)
    {:ok, departed} = PidroServer.RoomManagerCase.expire_phase(room.code, position, :phase2_start)
    old_pid = departed.seats[position].bot_pid
    assert :sys.get_state(old_pid).strategy == PidroServer.Games.Bots.Strategies.RulebookStrategy
    finish_game(room.code)
    ask_for_rematch(room, remaining)
    {:ok, restarted} = RoomManager.get_room(room.code)
    assert restarted.status == :playing
    assert restarted.config.bot_difficulty == :random
    {new_pid, bot} = current_bot(room.code, position)
    assert new_pid != old_pid
    assert bot.strategy == PidroServer.Games.Bots.Strategies.RulebookStrategy
  end

  # A substitute may be recovered while the old game registry entry retires.
  # Assert on the current seat owner after its initial continuation finishes.
  defp current_bot(room_code, position, attempts \\ 100)
  defp current_bot(_room_code, _position, 0), do: flunk("rematch substitute did not recover")

  defp current_bot(room_code, position, attempts) do
    result =
      try do
        {:ok, room} = RoomManager.get_room(room_code)
        pid = room.seats[position].bot_pid
        if is_pid(pid), do: {pid, :sys.get_state(pid)}
      catch
        :exit, _reason -> nil
      end

    if result do
      result
    else
      Process.sleep(10)
      current_bot(room_code, position, attempts - 1)
    end
  end

  describe "solo with bots" do
    @tag timeout: 120_000
    test "Louisiana solo production bots complete a real game to 62 and rematch preserves rules" do
      previous = Application.get_env(:pidro_server, Lifecycle, [])

      Application.put_env(
        :pidro_server,
        Lifecycle,
        Keyword.merge(previous,
          dealer_selection_delay_ms: 1,
          trick_transition_delay_ms: 1,
          hand_transition_delay_ms: 1,
          second_deal_transition_delay_ms: 1,
          bot_delay_ms: 1,
          bot_delay_variance_ms: 0,
          bot_min_delay_ms: 1
        )
      )

      on_exit(fn -> Application.put_env(:pidro_server, Lifecycle, previous) end)

      user = AccountsFixtures.user_fixture()
      {:ok, room} = RoomManager.create_room(user.id, %{solo: true, rule_set: :louisiana})

      for position <- [:east, :south, :west] do
        {:ok, _} = BotManager.start_bot(room.code, position, :basic, 1)
      end

      assert RoomFixtures.ready_room(room.code).status == :playing
      {:ok, state} = GameAdapter.get_state(room.code)
      assert state.variant == :louisiana
      assert state.config.min_bid == 7

      drive_louisiana(room.code, System.monotonic_time(:millisecond) + 90_000)
      {:ok, finished} = RoomManager.get_room(room.code)
      assert finished.status == :finished
      {:ok, state} = GameAdapter.get_state(room.code)
      assert Enum.max(Map.values(state.cumulative_scores)) >= 62
      assert Repo.get_by!(GameStats, room_code: room.code).rule_set == "louisiana"

      [started] = ask_for_rematch(room, [user.id])
      assert started.status == :playing
      assert started.config.rule_set == "louisiana"
      {:ok, rematch} = RoomManager.get_room(room.code)
      assert rematch.config.rule_set == :louisiana
      {:ok, next} = GameAdapter.get_state(room.code)
      assert next.variant == :louisiana
      assert next.config.min_bid == 7
    end

    test "the bots stay seated after game over and the rematch starts on the human's word" do
      user = AccountsFixtures.user_fixture(%{display_name: "Solo"})
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Solo", bot_difficulty: :smart})

      for position <- [:east, :south, :west] do
        {:ok, _pid} = BotManager.start_bot(room.code, position, :smart, 5_000)
      end

      playing = RoomFixtures.ready_room(room.code)
      assert playing.status == :playing

      bots = for {pos, %{occupant_type: :bot, bot_pid: pid}} <- playing.seats, do: {pos, pid}
      assert length(bots) == 3
      personas = Map.new(bots, fn {pos, _pid} -> {pos, playing.seats[pos].bot_persona} end)
      assert Enum.sort(Map.values(personas)) == ~w(antti jocke marcel)

      finished = finish_game(room.code)

      for {position, pid} <- bots do
        assert Process.alive?(pid)
        assert finished.seats[position].bot_pid == pid
        assert finished.seats[position].bot_persona == personas[position]
      end

      {:ok, vote} = RoomManager.readiness(room.code)
      assert vote.ready_players == [:east, :south, :west]

      [started] = ask_for_rematch(room, [user.id])
      assert started.status == :playing

      {:ok, rematch} = RoomManager.get_room(room.code)
      assert rematch.config.bot_difficulty == :smart

      for {position, pid} <- bots do
        assert rematch.seats[position].bot_pid == pid
        assert rematch.seats[position].bot_persona == personas[position]
      end

      {:ok, state} = GameAdapter.get_state(room.code)
      assert state.phase == :dealer_selection
    end

    test "a bot restarted by its supervisor gets its seat back" do
      user = AccountsFixtures.user_fixture(%{display_name: "Solo"})
      {:ok, room} = RoomManager.create_room(user.id, %{name: "Solo"})
      {:ok, pid} = BotManager.start_bot(room.code, :east, :basic, 5_000)
      {:ok, seated} = RoomManager.get_room(room.code)
      assert seated.seats.east.bot_pid == pid
      {:ok, before} = RoomManager.readiness(room.code)

      bot_id = seated.positions.east
      replacement = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, _room, :east} = RoomManager.join_bot(room.code, bot_id, replacement, :east)

      {:ok, reattached} = RoomManager.get_room(room.code)
      assert reattached.seats.east.bot_pid == replacement
      assert {:ok, ^before} = RoomManager.readiness(room.code)
    end
  end

  defp drive_louisiana(code, deadline) do
    assert System.monotonic_time(:millisecond) < deadline, "real Louisiana game timed out"
    {:ok, room} = RoomManager.get_room(code)

    if room.status != :finished do
      {:ok, state} = GameAdapter.get_state(code)
      {:ok, actions} = GameAdapter.get_legal_actions(code, :north)

      # Every seat may cut for dealer, so the driver leaves the cut to the bots
      # and waits for the dealer-selection timer to deal rather than race them.
      if state.phase != :dealer_selection and actions != [] do
        view = Pidro.Core.SeatView.for_seat(state, :north)

        {:ok, action, _} =
          PidroServer.Games.Bots.Strategies.RulebookStrategy.pick_action(actions, view)

        action = PidroServer.Games.Bots.BotBrain.resolve_action(action, state, :north)
        assert {:ok, _} = GameAdapter.apply_action(code, :north, action)
      end

      Process.sleep(2)
      drive_louisiana(code, deadline)
    end
  end

  describe "nobody agrees" do
    test "the finished room closes on its timer" do
      {room, _user_ids} = four_player_game()
      finish_game(room.code)

      Process.sleep(Lifecycle.config(:finished_room_ttl_ms) + 200)
      assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    end

    test "a rematch outlives the close timer of the game before it" do
      {room, user_ids} = four_player_game()
      finish_game(room.code)
      ask_for_rematch(room, user_ids)

      Process.sleep(Lifecycle.config(:finished_room_ttl_ms) + 200)
      assert {:ok, %{status: :playing}} = RoomManager.get_room(room.code)
    end
  end

  describe "the channel event" do
    setup do
      users = Enum.map(1..4, &AccountsFixtures.user_fixture(%{display_name: "Channel #{&1}"}))
      [host | others] = users
      {:ok, room} = RoomManager.create_room(host.id, %{})
      for user <- others, do: RoomManager.join_room(room.code, user.id)

      sockets =
        Enum.map(users, fn user ->
          {:ok, socket} = create_socket(user)
          {:ok, reply, joined} = subscribe_and_join(socket, GameChannel, "game:#{room.code}")
          {joined, reply}
        end)

      [{_socket, %{readiness: initial}} | _] = sockets
      params = %{"room_id" => room.id, "ready_epoch" => initial.ready_epoch}

      for {socket, _reply} <- sockets do
        ref = push(socket, "ready", params)
        assert_reply ref, :ok, _
      end

      %{room: room, sockets: Enum.map(sockets, &elem(&1, 0))}
    end

    test "rematch takes the ready payload and the last one starts the game", %{
      room: room,
      sockets: [first | rest] = sockets
    } do
      {:ok, %{game_instance_id: first_instance}} = GameAdapter.get_snapshot(room.code)
      finish_game(room.code)
      assert_push "readiness_updated", %{status: :finished, ready_players: [], ready_epoch: epoch}

      ref = push(first, "rematch", %{})
      assert_reply ref, :error, %{reason: "invalid_readiness"}

      ref = push(first, "rematch", %{"room_id" => room.id, "ready_epoch" => epoch - 1})
      assert_reply ref, :error, %{reason: "stale_readiness"}

      params = %{"room_id" => room.id, "ready_epoch" => epoch}
      ref = push(first, "rematch", params)
      assert_reply ref, :ok, %{readiness: %{status: :finished, ready_players: [:north]}}

      for socket <- rest do
        ref = push(socket, "rematch", params)
        assert_reply ref, :ok, _
      end

      assert_push "readiness_updated", %{status: :playing}
      assert {:ok, %{status: :playing, game_number: 2}} = RoomManager.get_room(room.code)

      # Every socket accepted snapshots from the first game's instance. The
      # rematch is a new instance and its state must still reach them.
      {:ok, %{game_instance_id: second_instance}} = GameAdapter.get_snapshot(room.code)
      refute second_instance == first_instance

      for _socket <- sockets do
        assert_push "game_state", %{game_instance_id: ^second_instance, state: state}
        assert state.phase in [:dealer_selection, "dealer_selection"]
      end

      assert length(sockets) == 4
    end
  end
end
