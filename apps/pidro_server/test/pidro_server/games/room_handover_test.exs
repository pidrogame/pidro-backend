defmodule PidroServer.Games.RoomHandoverTest do
  @moduledoc """
  A deploy moves rooms between nodes through `live_rooms`. One BEAM plays
  both nodes here: restarting the RoomManager gives it a new boot id, which
  is all a second node is to the room store.
  """
  use PidroServer.ArchiveCase, async: false

  alias PidroServer.GameArchive
  alias PidroServer.GameArchive.{Archive, Maintenance}
  alias PidroServer.Games.{GameAdapter, GameSupervisor, Lifecycle, RoomManager, RoomStore}
  alias PidroServer.Games.Room.Positions
  alias PidroServer.Stats.{AbandonmentEvent, SeatEvent}
  alias PidroServer.{AccountsFixtures, RoomFixtures, RoomManagerCase}
  alias PidroServerWeb.UserSocket

  setup do
    previous = Application.get_env(:pidro_server, Lifecycle, [])

    Application.put_env(
      :pidro_server,
      Lifecycle,
      Keyword.merge(previous,
        hiccup_timeout_ms: 60_000,
        grace_timeout_ms: 120_000,
        turn_timer_bid_ms: 600_000,
        turn_timer_play_ms: 600_000,
        dealer_selection_delay_ms: 0,
        deal_transition_delay_ms: 0
      )
    )

    on_exit(fn ->
      RoomManagerCase.cleanup()
      Application.put_env(:pidro_server, Lifecycle, previous)
    end)

    :ok
  end

  test "a write against a stale epoch is refused, and the old owner gives the room up" do
    {code, users} = table()
    {:ok, pid} = GameSupervisor.get_game(code)
    before = play_until(code, &(&1.phase == :bidding))
    for user <- users, do: Phoenix.PubSub.subscribe(PidroServer.PubSub, UserSocket.topic(user))

    # Node B takes the room over while this node still serves it.
    assert {:ok, %{epoch: 2}} = RoomStore.claim(code, "node-b", :force)
    ref = Process.monitor(pid)

    assert {:error, :game_unavailable} =
             GameAdapter.apply_action(code, before.state.current_turn, :pass)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    for _ <- users, do: assert_receive(%Phoenix.Socket.Broadcast{event: "disconnect"}, 1_000)
    refute Map.has_key?(:sys.get_state(RoomManager).rooms, code)

    summary = GameArchive.summary(before.game_instance_id)
    assert summary.last_revision == before.state_revision
    assert summary.status == "active"
    assert row(code) == ["node-b", 2, before.game_instance_id]

    # A checkpoint from the old epoch cannot land either.
    next = %{before | state_revision: before.state_revision + 1}
    fence = {:sys.get_state(RoomManager).boot_id, 1}
    assert {:error, :fenced} = GameArchive.commit(code, %{}, next, %{kind: :pace}, fence)
    assert GameArchive.summary(before.game_instance_id).last_revision == before.state_revision
  end

  test "a game the database is a move ahead of comes back from the database" do
    {code, _users} = table()
    before = play_until(code, &(&1.phase == :bidding))
    turn = before.state.current_turn

    # A move whose save committed although its game never heard back.
    {:ok, ahead} = Pidro.Game.Engine.apply_action(before.state, turn, {:bid, 10})
    saved = %{before | state: ahead, state_revision: before.state_revision + 1}
    cause = %{kind: :action, position: turn, action: {:bid, 10}, engine_events: []}
    :ok = GameArchive.checkpoint!(code, %{}, saved, cause)

    assert {:error, :game_unavailable} = GameAdapter.apply_action(code, turn, :pass)
    wait(fn -> not Map.has_key?(:sys.get_state(RoomManager).rooms, code) end)

    assert {:ok, _room} = RoomManager.get_room(code)
    assert {:ok, restored} = GameAdapter.get_snapshot(code)
    assert restored.state_revision == before.state_revision + 1
    assert %{restored.state | events: []} == %{ahead | events: []}
  end

  test "only a join takes a room from a live owner, and a node takes back a row it holds" do
    {code, _users} = table()
    before = play_until(code, &(&1.phase == :bidding))
    new_node()

    # The previous manager still heartbeats: a lobby read or invite preview
    # leaves the room with it.
    assert {:error, :room_not_found} = RoomManager.get_room(code)
    assert [_old, 1, _] = row(code)

    # A takeover that committed, though its answer never came back.
    boot_id = :sys.get_state(RoomManager).boot_id
    Repo.query!("UPDATE live_rooms SET owner = $2, epoch = 2 WHERE code = $1", [code, boot_id])

    assert {:ok, _room} = RoomManager.get_room(code)
    assert [^boot_id, 3, _] = row(code)
    assert {:ok, %{state_revision: revision}} = GameAdapter.get_snapshot(code)
    assert revision == before.state_revision
  end

  test "a game taken over mid-bidding comes back exactly and plays to the end" do
    {code, _users} = table()
    before = play_until(code, &(&1.phase == :bidding and &1.bids != []))
    assert_restores_and_finishes(code, before)
  end

  test "a game taken over mid-trick comes back exactly and plays to the end" do
    {code, _users} = table()

    before =
      play_until(code, &(&1.phase == :playing and match?(%{plays: [_ | _]}, &1.current_trick)))

    assert_restores_and_finishes(code, before)
  end

  test "a restore holds the humans without a drop, a bot or an abandonment" do
    {code, [north, east | _]} = table()
    play_until(code, &(&1.phase == :bidding))

    # East had dropped before the deploy and a substitute covers the seat.
    RoomManager.handle_player_disconnect(code, east)
    {:ok, _} = RoomManagerCase.expire_phase(code, :east, :phase2_start)
    wait(fn -> event_count(SeatEvent) == 1 end)

    new_node()
    {:ok, room} = RoomManager.find_room(code)

    for position <- [:north, :south, :west] do
      assert %{occupant_type: :human, status: :reconnecting} = room.seats[position]
      assert is_reference(room.phase_timers[position])
    end

    assert %{status: :bot_substitute, reserved_for: ^east, bot_pid: bot} = room.seats.east
    assert Process.alive?(bot)
    assert is_reference(room.phase_timers.east)

    # Only east's own drop is on record; the deploy added none.
    Process.sleep(100)
    assert event_count(SeatEvent) == 1
    assert event_count(AbandonmentEvent) == 0

    assert {:ok, back} = RoomManager.handle_player_reconnect(code, north)
    assert back.seats.north.status == :connected
    refute Map.has_key?(back.phase_timers, :north)
  end

  test "a finished room comes back with its game over, its summary and its players" do
    {code, users} = table()
    final = play_until(code, &(&1.phase == :complete))
    wait(fn -> RoomManager.get_room(code) |> elem(1) |> Map.get(:status) == :finished end)
    {:ok, before} = RoomManager.get_room(code)

    new_node()
    assert {:ok, room} = RoomManager.find_room(code)
    assert room.status == :finished
    # Kept as the JSON a rejoin sends.
    assert room.post_game_summaries != %{}
    assert room.post_game_summaries == Jason.decode!(Jason.encode!(before.post_game_summaries))
    assert Enum.sort(Positions.player_ids(room)) == Enum.sort(users)
    assert {:ok, restored} = GameAdapter.get_snapshot(code)
    assert restored.state == final.state
    assert GameArchive.summary(final.game_instance_id).status == "complete"
  end

  test "on shutdown a node releases its rooms and the next node takes them" do
    {code, users} = table()
    before = play_until(code, &(&1.phase == :bidding))
    for user <- users, do: Phoenix.PubSub.subscribe(PidroServer.PubSub, UserSocket.topic(user))

    assert :ok = RoomManager.release_rooms()

    for _ <- users, do: assert_receive(%Phoenix.Socket.Broadcast{event: "disconnect"}, 1_000)
    assert {:error, :not_found} = GameSupervisor.get_game(code)
    assert [nil, 1, _] = row(code)
    assert GameArchive.summary(before.game_instance_id).status == "active"
    # A node handing over takes nothing back.
    assert {:error, :room_moving} = RoomManager.find_room(code)

    new_node()
    send(RoomManager, :room_store_sweep)
    wait(fn -> Map.has_key?(:sys.get_state(RoomManager).rooms, code) end)
    assert {:ok, after_restore} = GameAdapter.get_snapshot(code)
    assert after_restore.state == before.state
    assert [_owner, 2, _] = row(code)
  end

  test "the archive keeps a moved game active, and interrupts one no room runs" do
    {code, _users} = table()
    before = play_until(code, &(&1.phase == :bidding))
    {:ok, _} = RoomStore.claim(code, "node-b", :force)
    send(RoomManager, :room_store_sweep)
    wait(fn -> GameSupervisor.get_game(code) == {:error, :not_found} end)

    stale = DateTime.add(DateTime.utc_now(), -121, :second)
    id = before.game_instance_id
    Repo.update_all(from(a in Archive, where: a.game_instance_id == ^id), set: [saved_at: stale])

    assert Maintenance.reconcile() == nil
    assert GameArchive.summary(id).status == "active"

    Repo.query!("DELETE FROM live_rooms WHERE code = $1", [code])
    assert Maintenance.reconcile() == nil
    assert GameArchive.summary(id).status == "interrupted"
  end

  defp assert_restores_and_finishes(code, before) do
    new_node()
    assert {:ok, room} = RoomManager.find_room(code)
    assert room.status == :playing
    assert {:ok, restored} = GameAdapter.get_snapshot(code)

    assert restored.game_instance_id == before.game_instance_id
    assert restored.state_revision == before.state_revision
    # Hands, deck and chance, scores, dealer, turn and events: all of it.
    assert restored.state == before.state
    assert [_owner, 2, _] = row(code)

    final = play_until(code, &(&1.phase == :complete))
    summary = GameArchive.summary(before.game_instance_id)
    assert summary.status == "complete"
    assert summary.last_revision == final.state_revision
    assert summary.missing_revision_count == 0
    assert summary.evidence_status == "continuous"
  end

  defp table do
    users = for _ <- 1..4, do: AccountsFixtures.user_fixture().id
    [host | guests] = users
    {:ok, room} = RoomManager.create_room(host, %{})
    for guest <- guests, do: {:ok, _, _} = RoomManager.join_room(room.code, guest)
    RoomFixtures.ready_room(room.code)
    {room.code, users}
  end

  # Plays deterministic moves until `done?` holds, then returns the snapshot.
  defp play_until(code, done?, moves \\ 2_000) do
    {:ok, snapshot} = GameAdapter.get_snapshot(code)

    cond do
      done?.(snapshot.state) ->
        snapshot

      moves == 0 ->
        flunk("game never reached the state; stuck in #{snapshot.state.phase}")

      snapshot.state.phase == :dealer_selection and snapshot.state.dealer_selection_cuts ->
        Process.sleep(5)
        play_until(code, done?, moves - 1)

      snapshot.state.phase == :dealer_selection ->
        {:ok, _} = GameAdapter.apply_action(code, :north, :select_dealer)
        play_until(code, done?, moves - 1)

      true ->
        state = snapshot.state
        action = Pidro.Test.DeterministicGame.action(state)

        # The server plays a settled hand out itself, so a move can race it.
        case GameAdapter.apply_action(code, state.current_turn, action) do
          {:ok, _} -> :ok
          {:error, {:not_your_turn, _}} -> :ok
        end

        play_until(code, done?, moves - 1)
    end
  end

  # The room as the old node last saved it is what the new node restores, so
  # let the save that follows a change land first.
  defp new_node do
    wait(fn ->
      state = :sys.get_state(RoomManager)
      Enum.all?(state.rooms, fn {code, room} -> match?({^room, _}, state.saved[code]) end)
    end)

    :ok = Supervisor.terminate_child(PidroServer.Games.Supervisor, RoomManager)
    {:ok, _} = Supervisor.restart_child(PidroServer.Games.Supervisor, RoomManager)
    :ok
  end

  defp row(code) do
    %{rows: [row]} =
      Repo.query!("SELECT owner, epoch, game_instance_id FROM live_rooms WHERE code = $1", [code])

    row
  end

  defp event_count(schema), do: Repo.aggregate(schema, :count)

  defp wait(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait(fun, attempts - 1)
    end
  end
end
