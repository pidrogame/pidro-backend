defmodule PidroServer.GameArchiveTest do
  use PidroServer.ArchiveCase, async: false

  alias PidroServer.GameArchive
  alias PidroServer.GameArchive.{Archive, Event, Maintenance, Serialization}
  alias PidroServer.Games.{GameAdapter, GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.{AccountsFixtures, RoomFixtures}

  setup do
    RoomManager.reset_for_test()
    previous = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.merge(previous,
        turn_timer_bid_ms: 600_000,
        turn_timer_play_ms: 600_000,
        finished_room_ttl_ms: 600_000,
        dealer_selection_delay_ms: 0,
        deal_transition_delay_ms: 0,
        trick_transition_delay_ms: 0,
        hand_transition_delay_ms: 0,
        second_deal_transition_delay_ms: 0,
        bot_delay_ms: 1,
        bot_delay_variance_ms: 0,
        bot_min_delay_ms: 1
      )
    )

    on_exit(fn ->
      PidroServer.RoomManagerCase.cleanup()
      Application.put_env(:pidro_server, Lifecycle, previous)
    end)

    :ok
  end

  test "solo start/play/leave retains actual first deal, private seats, and last state after death" do
    host = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{solo: true})
    for pos <- [:east, :south, :west], do: BotManager.start_bot(room.code, pos, :basic, 5_000)
    playing = RoomFixtures.ready_room(room.code)
    {:ok, pid} = GameSupervisor.get_game(room.code)
    {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)
    wait(fn -> Pidro.Server.get_state(pid).phase == :bidding end)
    live = Pidro.Server.get_snapshot(pid)
    id = live.game_instance_id
    assert {:ok, _} = GameAdapter.apply_action(room.code, live.state.current_turn, :pass)

    ref = Process.monitor(pid)
    assert :ok = RoomManager.leave_room(host.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:error, :room_not_found} = RoomManager.get_room(room.code)
    summary = GameArchive.summary(id)
    assert summary.status == "closed"
    assert summary.termination_reason == "room_closed"
    assert summary.evidence_status == "continuous"
    assert summary.participants["north"]["user_id"] == host.id

    for pos <- [:east, :south, :west] do
      assert summary.participants[to_string(pos)]["bot_persona"] == playing.seats[pos].bot_persona
      refute Map.has_key?(summary.participants[to_string(pos)], "bot_pid")
    end

    assert GameArchive.initial_snapshot(id)["state_revision"] == 0
    deal = GameArchive.initial_deal(id)
    assert deal["state"]["deck"] == Serialization.encode(live.state.deck)

    assert deal["state"]["players"]["east"]["hand"] ==
             Serialization.encode(live.state.players.east.hand)

    assert length(deal["state"]["players"]["east"]["hand"]) == 9
    assert GameArchive.last_snapshot(id)["state_revision"] > live.state_revision
    assert [first, second] = GameArchive.events(id, limit: 2)
    assert [first.revision, second.revision] == [0, 1]
    assert Enum.map(GameArchive.events(id, after_revision: 1), & &1.revision) == [2, 3]

    assert [%{game_instance_id: ^id}] =
             GameArchive.search(user_id: host.id, room_code: room.code, status: "closed")

    assert GameArchive.search(from: DateTime.add(summary.started_at, 1, :second)) == []
    assert GameArchive.search(to: summary.started_at) == []
    assert GameArchive.get(id) == summary
    assert GameArchive.snapshot(id, :initial_deal) == deal
    assert GameArchive.snapshot(id, 2) == deal
    assert GameArchive.step(id, 1).revision == 2
    assert GameArchive.step(id, 3) == nil
    assert GameArchive.participant?(id, room.code, host.id)
    refute GameArchive.participant?(id, "DIFF", host.id)
    refute GameArchive.participant?("different-instance", room.code, host.id)
    refute GameArchive.participant?(id, room.code, Ecto.UUID.generate())
    refute GameArchive.participant?(id, room.code, nil)
  end

  @tag timeout: 120_000
  test "a real completed game and its abandoned rematch have distinct histories in the same room" do
    {room, users} = four_humans()
    RoomFixtures.ready_room(room.code)
    {:ok, first} = GameAdapter.get_snapshot(room.code)
    {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)
    wait(fn -> match?({:ok, %{phase: :bidding}}, GameAdapter.get_state(room.code)) end)
    drive(room.code, 5_000)
    first_summary = GameArchive.summary(first.game_instance_id)
    assert first_summary.status == "complete"
    assert first_summary.last_revision > 100
    {:ok, %{status: :finished}} = RoomManager.get_room(room.code)
    {:ok, %{ready_epoch: epoch}} = RoomManager.readiness(room.code)
    for user <- users, do: RoomManager.confirm_rematch(room.code, room.id, user, self(), epoch)
    {:ok, second} = GameAdapter.get_snapshot(room.code)
    refute first.game_instance_id == second.game_instance_id
    assert second.state_revision == 0
    assert :ok = GameSupervisor.stop_game(room.code)
    assert GameArchive.summary(second.game_instance_id).status == "closed"
    assert GameArchive.summary(first.game_instance_id).status == "complete"
    assert length(GameArchive.search(room_code: room.code)) == 2
    assert length(GameArchive.events(second.game_instance_id)) == 1
    assert GameArchive.last_snapshot(first.game_instance_id)["state"]["phase"] == "complete"
  end

  test "leaving a continuing multiplayer table does not close its archive" do
    {room, [_host, departing | _]} = four_humans()
    RoomFixtures.ready_room(room.code)
    {:ok, pid} = GameSupervisor.get_game(room.code)
    id = Pidro.Server.get_snapshot(pid).game_instance_id
    assert :ok = RoomManager.leave_room(departing)
    assert Process.alive?(pid)
    assert GameArchive.summary(id).status == "active"
    {:ok, %{status: :playing}} = RoomManager.get_room(room.code)
  end

  test "a replacement who plays and leaves remains a durable participant after closure, including outage recovery" do
    config = Application.get_env(:pidro_server, Lifecycle)
    Application.put_env(:pidro_server, Lifecycle, Keyword.put(config, :bot_delay_ms, 5_000))
    {room, [host, departing | _]} = four_humans()
    RoomFixtures.ready_room(room.code)
    {:ok, pid} = GameSupervisor.get_game(room.code)
    id = Pidro.Server.get_snapshot(pid).game_instance_id
    spectator = AccountsFixtures.user_fixture().id
    replacement = AccountsFixtures.user_fixture().id
    assert {:ok, _} = RoomManager.join_spectator_room(room.code, spectator)
    :ok = RoomManager.leave_room(departing)
    {:ok, _} = RoomManager.open_seat(room.code, :east, host)

    Repo.query!(
      "ALTER TABLE game_archives ADD CONSTRAINT participation_outage CHECK (false) NOT VALID"
    )

    assert {:ok, _, :east} = RoomManager.join_as_substitute(room.code, replacement)
    refute GameArchive.participant?(id, room.code, replacement)
    # A room's game makes no move it cannot save.
    assert {:error, :game_unavailable} =
             GameAdapter.apply_action(room.code, :north, :select_dealer)

    Repo.query!("ALTER TABLE game_archives DROP CONSTRAINT participation_outage")
    assert {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)
    wait(fn -> Pidro.Server.get_state(pid).phase == :bidding end)

    for _ <- 1..4 do
      state = Pidro.Server.get_state(pid)

      assert {:ok, _} =
               GameAdapter.apply_action(
                 room.code,
                 state.current_turn,
                 Pidro.Test.DeterministicGame.action(state)
               )
    end

    assert Enum.any?(Pidro.Server.get_state(pid).events, fn
             {:player_passed, :east} -> true
             {:bid_made, :east, _} -> true
             _ -> false
           end)

    :ok = RoomManager.leave_room(replacement)
    assert :ok = RoomManager.close_room(room.code)
    refute Process.alive?(pid)
    assert GameArchive.participant?(id, room.code, replacement)
    assert GameArchive.participant?(id, room.code, departing)
    refute GameArchive.participant?(id, room.code, spectator)
    refute GameArchive.participant?(id, "WRNG", replacement)
    refute GameArchive.participant?("other-instance", room.code, replacement)
    assert [%{game_instance_id: ^id}] = GameArchive.search(user_id: replacement)
    assert GameArchive.get(id).participants["east"]["user_id"] == departing
    # The failed participation write is on record; no revision is missing.
    assert GameArchive.get(id).evidence_status == "uncertain"
    assert GameArchive.get(id).missing_revision_count == 0
  end

  test "participation union is bounded and explicitly marked when truncated" do
    users = Enum.map(1..257, &"participant-#{&1}")

    GameArchive.checkpoint!("CAPD", %{}, snapshot("cap", 0), %{
      kind: :start,
      participant_user_ids: users
    })

    assert length(GameArchive.get("cap").user_ids) == 256
    assert GameArchive.get("cap").participation_truncated
    assert GameArchive.participant?("cap", "CAPD", "participant-256")
    refute GameArchive.participant?("cap", "CAPD", "participant-257")
  end

  test "duplicate transitions/finalization do not duplicate evidence; conflicting retries are rejected" do
    snapshot = snapshot("duplicate", 0)
    cause = %{kind: :start}
    assert :ok = GameArchive.checkpoint!("DUPL", %{}, snapshot, cause)
    assert :ok = GameArchive.checkpoint!("DUPL", %{}, snapshot, cause)
    assert length(GameArchive.events("duplicate")) == 1

    assert_raise RuntimeError, ~r/conflicting_revision/, fn ->
      GameArchive.checkpoint!("DUPL", %{}, snapshot, %{kind: :different})
    end

    assert {1, nil} = GameArchive.finalize("duplicate", "closed", "room_closed")
    assert {0, nil} = GameArchive.finalize("duplicate", "interrupted", "process_missing")
    assert GameArchive.summary("duplicate").termination_reason == "room_closed"
  end

  test "DB write outage accepts actions and broadcasts, then records a gap on recovery" do
    {:ok, pid} = GameSupervisor.start_game("FAIL")
    on_exit(fn -> GameSupervisor.stop_game("FAIL") end)
    id = Pidro.Server.get_snapshot(pid).game_instance_id
    assert GameArchive.summary(id).last_revision == 0
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:FAIL")
    outage()
    assert {:ok, _} = GameAdapter.apply_action("FAIL", :north, :select_dealer)
    assert_receive {:state_update, "FAIL", %{state_revision: 1}}, 1_000
    wait(fn -> Pidro.Server.get_state(pid).phase == :bidding end)
    state = Pidro.Server.get_state(pid)
    assert {:ok, _} = GameAdapter.apply_action("FAIL", state.current_turn, :pass)
    assert Process.alive?(pid)
    assert {:ok, %{status: :degraded, failures: failures}} = GameArchive.health("FAIL")
    assert failures >= 3
    assert GameArchive.summary(id).last_revision == 0
    recover()
    :ok = Pidro.Server.set_pace(pid, :own)
    assert {:ok, %{status: :healthy}} = GameArchive.health("FAIL")

    assert %{evidence_status: "partial", missing_revision_count: 3, failed_checkpoints: 3} =
             GameArchive.summary(id)

    assert [%{payload: %{"missing_revisions" => [1, 3]}}] =
             GameArchive.events(id, after_revision: 0)

    assert GameArchive.initial_deal(id)["state_revision"] == 2
    assert GameArchive.initial_deal(id)["state"]["phase"] == "bidding"
  end

  test "a room's game makes no move it cannot save, and its bots retry until they can" do
    host = AccountsFixtures.user_fixture()
    {:ok, room} = RoomManager.create_room(host.id, %{solo: true})

    bots =
      for pos <- [:east, :south, :west] do
        {:ok, bot} = BotManager.start_bot(room.code, pos, :basic, 1)
        PidroServer.Games.Bots.BotPlayer.pause(bot)
        # Consume the pause before readiness starts the game and its broadcasts.
        :sys.get_state(bot)
        bot
      end

    RoomFixtures.ready_room(room.code)
    {:ok, pid} = GameSupervisor.get_game(room.code)
    id = Pidro.Server.get_snapshot(pid).game_instance_id
    outage()

    assert {:error, :game_unavailable} =
             GameAdapter.apply_action(room.code, :north, :select_dealer)

    assert Pidro.Server.get_snapshot(pid).state_revision == 0
    recover()
    assert {:ok, _} = GameAdapter.apply_action(room.code, :north, :select_dealer)
    wait(fn -> Pidro.Server.get_state(pid).phase != :dealer_selection end)
    state = Pidro.Server.get_state(pid)

    if state.phase == :bidding and state.current_turn == :north,
      do: GameAdapter.apply_action(room.code, :north, :pass)

    outage()
    for bot <- bots, do: PidroServer.Games.Bots.BotPlayer.resume(bot)
    Process.sleep(300)
    refute Enum.any?(Pidro.Server.get_state(pid).events, &bot_bid?/1)
    recover()
    wait(fn -> Enum.any?(Pidro.Server.get_state(pid).events, &bot_bid?/1) end)
    assert Process.alive?(pid)

    for bot <- bots do
      PidroServer.Games.Bots.BotPlayer.pause(bot)
      :sys.get_state(bot)
    end

    Process.sleep(50)
    summary = GameArchive.summary(id)
    assert summary.last_revision == Pidro.Server.get_snapshot(pid).state_revision
    assert summary.evidence_status == "continuous"
    assert summary.missing_revision_count == 0
  end

  test "failed start can recover initial facts; process death and restart reconciliation are truthful" do
    outage()
    {:ok, pid} = GameSupervisor.start_game("BOOT", :louisiana)
    snapshot = Pidro.Server.get_snapshot(pid)
    assert GameArchive.summary(snapshot.game_instance_id) == nil
    recover()
    :ok = Pidro.Server.set_pace(pid, :own)
    assert GameArchive.initial_snapshot(snapshot.game_instance_id)["state_revision"] == 0
    assert GameArchive.summary(snapshot.game_instance_id).evidence_status == "partial"
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    {:ok, new_pid} = GameSupervisor.start_game("BOOT", :louisiana)
    on_exit(fn -> GameSupervisor.stop_game("BOOT") end)
    new_id = Pidro.Server.get_snapshot(new_pid).game_instance_id
    # A draining old node must not interrupt freshly saved games on the new node.
    assert Maintenance.reconcile() == nil
    assert GameArchive.summary(snapshot.game_instance_id).status == "active"
    stale = DateTime.add(DateTime.utc_now(), -121, :second)

    Repo.update_all(from(a in Archive, where: a.game_instance_id == ^snapshot.game_instance_id),
      set: [saved_at: stale]
    )

    assert Maintenance.reconcile() == nil
    assert GameArchive.summary(snapshot.game_instance_id).status == "interrupted"
    assert GameArchive.summary(new_id).status == "active"
    assert Maintenance.reconcile() == nil
    assert GameArchive.summary(snapshot.game_instance_id).termination_reason == "process_missing"
  end

  test "Finnish and Louisiana facts are JSON data with exact chance integers and no executable values" do
    for variant <- [:finnish, :louisiana] do
      id = to_string(variant)
      state = Pidro.Core.GameState.new(seed: 13, variant: variant)
      snapshot = %{snapshot(id, 0) | state: state}
      GameArchive.checkpoint!("JSON", %{}, snapshot, %{kind: :start})
      saved = GameArchive.last_snapshot(id)
      assert saved["state"]["variant"] == id
      assert saved == saved |> Jason.encode!() |> Jason.decode!()

      assert %{"$tuple" => ["exsss", %{"$improper_list" => [_], "$tail" => _}]} =
               saved["state"]["chance"]
    end

    assert Serialization.encode(9_007_199_254_740_993) == %{"$integer" => "9007199254740993"}

    for unsafe <- [self(), make_ref(), fn -> :ok end] do
      assert_raise ArgumentError, fn -> Serialization.encode(unsafe) end
    end
  end

  test "bounded retention removes only old terminal evidence, never stats or fresh/active games" do
    for id <- ~w(old older fresh active) do
      GameArchive.checkpoint!("KEEP", %{}, snapshot(id, 0), %{kind: :start})
      if id != "active", do: GameArchive.finalize(id, "closed", "room_closed")
    end

    old = DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)

    Repo.update_all(from(a in Archive, where: a.game_instance_id in ["old", "older"]),
      set: [ended_at: old]
    )

    stats =
      Repo.insert!(%PidroServer.Stats.GameStats{
        room_code: "KEEP",
        completed_at: DateTime.truncate(old, :second)
      })

    assert {1, nil} = GameArchive.cleanup(batch_size: 1)
    assert {1, nil} = GameArchive.cleanup(batch_size: 1)
    assert {0, nil} = GameArchive.cleanup()
    assert Repo.get(PidroServer.Stats.GameStats, stats.id)
    assert GameArchive.summary("active")
    assert GameArchive.summary("fresh")

    assert Repo.aggregate(from(e in Event, where: e.game_instance_id in ["old", "older"]), :count) ==
             0

    assert_raise ArgumentError, fn -> GameArchive.cleanup(batch_size: 1001) end
  end

  test "archive has no public HTTP route or channel event" do
    routes = Phoenix.Router.routes(PidroServerWeb.Router)
    refute Enum.any?(routes, &String.contains?(&1.path, "archive"))
    {:ok, pid} = GameSupervisor.start_game("PRIV")
    on_exit(fn -> GameSupervisor.stop_game("PRIV") end)
    snapshot = Pidro.Server.get_snapshot(pid)
    refute Map.has_key?(snapshot, :archive_health)
    refute Map.has_key?(snapshot, :checkpoint_initial)
  end

  defp snapshot(id, revision),
    do: %{
      game_instance_id: id,
      state_revision: revision,
      server_time_ms: System.system_time(:millisecond),
      presentation: %{},
      state: Pidro.Core.GameState.new(seed: 42)
    }

  defp four_humans do
    users = Enum.map(1..4, fn _ -> AccountsFixtures.user_fixture().id end)
    [host | others] = users
    {:ok, room} = RoomManager.create_room(host)
    for user <- others, do: RoomManager.join_room(room.code, user)
    {room, users}
  end

  defp outage,
    do:
      Repo.query!(
        "ALTER TABLE game_archive_events ADD CONSTRAINT archive_test_outage CHECK (false) NOT VALID"
      )

  defp recover,
    do: Repo.query!("ALTER TABLE game_archive_events DROP CONSTRAINT archive_test_outage")

  defp bot_bid?({:bid_made, pos, _}) when pos != :north, do: true
  defp bot_bid?({:player_passed, pos}) when pos != :north, do: true
  defp bot_bid?(_), do: false

  defp drive(room, remaining) when remaining > 0 do
    {:ok, state} = GameAdapter.get_state(room)

    if state.phase != :complete do
      action = Pidro.Test.DeterministicGame.action(state)
      assert {:ok, _} = GameAdapter.apply_action(room, state.current_turn, action)
      drive(room, remaining - 1)
    end
  end

  defp wait(fun, attempts \\ 200)
  defp wait(fun, 0), do: assert(fun.())

  defp wait(fun, attempts) do
    unless fun.() do
      Process.sleep(10)
      wait(fun, attempts - 1)
    end
  end
end
