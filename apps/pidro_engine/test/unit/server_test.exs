defmodule Pidro.ServerTest do
  use ExUnit.Case, async: true

  alias Pidro.Server
  alias Pidro.Core.GameState
  alias Pidro.Core.Types.GameState, as: GameStateType

  describe "own pace" do
    for variant <- [:finnish, :louisiana] do
      test "#{variant} scores but does not deal until continued" do
        base = GameState.new(seed: 1, variant: unquote(variant), config: %{pace: :own})

        players =
          Map.new(base.players, fn {position, player} ->
            hand = if position == :west, do: [{4, :hearts}], else: []
            {position, %{player | hand: hand}}
          end)

        initial = %{
          base
          | phase: :playing,
            current_turn: :west,
            current_dealer: :west,
            trump_suit: :hearts,
            highest_bid: {:north, 7},
            bidding_team: :north_south,
            players: players,
            trick_number: 1,
            current_trick: %Pidro.Core.Types.Trick{
              number: 1,
              leader: :north,
              plays: [north: {14, :hearts}, east: {3, :hearts}, south: {2, :hearts}]
            }
        }

        pid = start_supervised!({Server, initial_state: initial})
        assert {:ok, held} = Server.apply_action(pid, :west, {:play_card, {4, :hearts}})
        assert held.phase == :hand_complete
        assert held.hand_number == 1
        assert held.last_hand != nil
        assert held.chance == initial.chance
        assert Server.legal_actions(pid, :north) == []

        assert :ok = Server.continue_hand(pid)
        dealt = Server.get_state(pid)
        assert dealt.phase == :bidding
        assert dealt.hand_number == 2
        assert Enum.all?(dealt.players, fn {_, player} -> length(player.hand) == 9 end)
        assert :ok = Server.continue_hand(pid)
        assert Server.get_state(pid) == dealt
      end
    end
  end

  describe "start_link/1" do
    test "Louisiana and explicit config survive server startup and reset" do
      pid =
        start_supervised!({Server, seed: 1, variant: :louisiana, config: %{winning_score: 80}})

      state = Server.get_state(pid)
      assert state.variant == :louisiana
      assert state.config.min_bid == 7
      assert state.config.winning_score == 80
      assert :ok = Server.reset(pid)
      assert Server.get_state(pid) == state
    end

    test "starts server with default options" do
      assert {:ok, pid} = Server.start_link()
      assert Process.alive?(pid)
    end

    test "starts server with game_id" do
      assert {:ok, pid} = Server.start_link(game_id: "test_game")
      state = Server.get_state(pid)
      assert state.phase == :dealer_selection
    end

    test "starts server with initial state" do
      initial_state = %GameStateType{GameState.new(seed: 1) | hand_number: 5}
      assert {:ok, pid} = Server.start_link(initial_state: initial_state)
      state = Server.get_state(pid)
      assert state.hand_number == 5
    end

    test "starts server with telemetry disabled" do
      assert {:ok, pid} = Server.start_link(telemetry: false)
      assert Process.alive?(pid)
    end
  end

  describe "get_state/1" do
    test "returns current game state" do
      {:ok, pid} = Server.start_link()
      state = Server.get_state(pid)
      assert %GameStateType{} = state
      assert state.phase == :dealer_selection
    end
  end

  describe "authoritative snapshots" do
    test "an applied action whose caller timed out is replayed, not applied again" do
      checkpoint = fn _snapshot, cause ->
        if cause.kind == :action, do: Process.sleep(30)
        :ok
      end

      {:ok, pid} = Server.start_link(checkpoint: checkpoint, dealer_selection_delay_ms: 60_000)
      key = {"player", "lost-reply"}
      assert catch_exit(Server.apply_action_with_snapshot(pid, :north, :select_dealer, 1, key))
      before = Server.get_snapshot(pid)
      assert before.state_revision == 1

      assert {:replayed, original} =
               Server.apply_action_with_snapshot(pid, :north, :select_dealer, 1_000, key)

      assert original == before.state
      assert Server.get_snapshot(pid).state_revision == 1
      :ok = Server.reset(pid)

      assert {:ok, _, _} =
               Server.apply_action_with_snapshot(pid, :north, :select_dealer, 1_000, key)
    end

    test "a rejected action_id may be applied later and IDs are scoped to players" do
      {:ok, pid} = Server.start_link(dealer_selection_delay_ms: 60_000)
      key = {"player", "retry"}
      assert {:error, _} = Server.apply_action_with_snapshot(pid, :north, :pass, 1_000, key)

      assert {:ok, _, _} =
               Server.apply_action_with_snapshot(pid, :north, :select_dealer, 1_000, key)

      assert {:error, _} =
               Server.apply_action_with_snapshot(pid, :east, :pass, 1_000, {"other", "retry"})

      assert Server.get_snapshot(pid).state_revision == 1
    end

    test "keeps one dealer-selection window across reads and clears it on advance" do
      {:ok, pid} = Server.start_link(dealer_selection_delay_ms: 80)

      assert {:ok, old_state, selected} =
               Server.apply_action_with_snapshot(pid, :north, :select_dealer)

      assert old_state.dealer_selection_cuts == nil
      assert selected.state.phase == :dealer_selection
      assert selected.state.current_dealer in [:north, :east, :south, :west]
      assert selected.state_revision == 1
      assert is_binary(selected.game_instance_id)

      window = selected.presentation.dealer_selection
      assert window.ends_at_ms - window.started_at_ms == 80
      assert selected.server_time_ms >= window.started_at_ms

      Process.sleep(20)
      catch_up = Server.get_snapshot(pid)
      assert catch_up.state_revision == selected.state_revision
      assert catch_up.presentation.dealer_selection == window
      assert catch_up.server_time_ms > selected.server_time_ms

      Process.sleep(80)
      advanced = Server.get_snapshot(pid)
      assert advanced.state.phase == :bidding
      assert advanced.state_revision == 2
      assert advanced.presentation.dealer_selection == nil
    end

    test "a slow or absent consumer never extends the server deadline" do
      {:ok, pid} = Server.start_link(dealer_selection_delay_ms: 30)
      assert {:ok, _state} = Server.apply_action(pid, :north, :select_dealer)

      Process.sleep(50)

      assert %{
               state: %{phase: :bidding},
               presentation: %{dealer_selection: nil, dealer_rob: nil}
             } =
               Server.get_snapshot(pid)
    end

    test "a queued timer from a replaced state cannot advance the replacement" do
      {:ok, pid} = Server.start_link(dealer_selection_delay_ms: 10_000)
      assert {:ok, _state} = Server.apply_action(pid, :north, :select_dealer)

      %{dealer_selection_token: stale_token} = :sys.get_state(pid)
      assert :ok = Server.reset(pid)
      send(pid, {:advance_from_dealer_selection, stale_token})
      Process.sleep(10)

      snapshot = Server.get_snapshot(pid)
      assert snapshot.state.phase == :dealer_selection
      assert snapshot.state.dealer_selection_cuts == nil
      assert snapshot.presentation.dealer_selection == nil
    end

    test "briefly exposes the authoritative dealer pool after a manual rob" do
      base = GameState.new(seed: 1)
      dealer_hand = [{14, :diamonds}, {5, :hearts}, {4, :diamonds}]
      stock = [{5, :diamonds}, {13, :diamonds}, {12, :diamonds}, {3, :clubs}]
      dealer = %{base.players.north | hand: dealer_hand}

      initial_state = %GameStateType{
        base
        | phase: :second_deal,
          current_dealer: :north,
          current_turn: :north,
          trump_suit: :diamonds,
          highest_bid: {:north, 10},
          players: Map.put(base.players, :north, dealer),
          deck: stock
      }

      selected = [
        {14, :diamonds},
        {5, :hearts},
        {5, :diamonds},
        {13, :diamonds},
        {12, :diamonds},
        {4, :diamonds}
      ]

      {:ok, pid} =
        Server.start_link(
          initial_state: initial_state,
          dealer_rob_presentation_ms: 40,
          telemetry: false
        )

      assert {:ok, _old_state, snapshot} =
               Server.apply_action_with_snapshot(pid, :north, {:select_hand, selected})

      assert snapshot.state.phase == :playing
      assert snapshot.presentation.dealer_rob.dealer == :north
      assert snapshot.presentation.dealer_rob.automatic == false
      assert snapshot.presentation.dealer_rob.kept == selected
      assert snapshot.presentation.dealer_rob.discarded == [{3, :clubs}]

      assert Enum.sort(snapshot.presentation.dealer_rob.pool) ==
               Enum.sort(selected ++ [{3, :clubs}])

      Process.sleep(60)
      cleared = Server.get_snapshot(pid)
      assert cleared.presentation.dealer_rob == nil
      assert cleared.state_revision == snapshot.state_revision + 1
    end
  end

  describe "apply_action/3" do
    test "applies valid action and returns new state" do
      {:ok, pid} = Server.start_link(dealer_selection_delay_ms: 0)

      # Get initial legal actions
      actions = Server.legal_actions(pid, :north)

      # After select_dealer, phase pauses at :dealer_selection with cuts populated.
      # The GenServer timer (0ms in tests) advances to dealing/bidding asynchronously.
      if :select_dealer in actions do
        {:ok, new_state} = Server.apply_action(pid, :north, :select_dealer)
        assert new_state.phase == :dealer_selection
        assert new_state.dealer_selection_cuts != nil

        # Wait for the async advance
        Process.sleep(50)
        advanced_state = Server.get_state(pid)
        assert advanced_state.phase != :dealer_selection
      end
    end

    test "returns error for invalid action" do
      {:ok, pid} = Server.start_link()
      # Try an action that's not legal in initial phase
      assert {:error, _reason} = Server.apply_action(pid, :north, {:bid, 10})
    end

    test "does not allow dealer selection to be repeated while cuts are visible" do
      {:ok, pid} = Server.start_link(dealer_selection_delay_ms: 10_000)

      assert {:ok, state} = Server.apply_action(pid, :north, :select_dealer)
      assert state.phase == :dealer_selection
      assert state.dealer_selection_cuts != nil

      assert Server.legal_actions(pid, :north) == []

      assert {:error, {:invalid_action, :select_dealer, :dealer_selection}} =
               Server.apply_action(pid, :east, :select_dealer)
    end

    test "updates server state after successful action" do
      {:ok, pid} = Server.start_link()

      # Find a legal action
      actions = Server.legal_actions(pid, :north)

      if length(actions) > 0 do
        action = hd(actions)
        {:ok, _new_state} = Server.apply_action(pid, :north, action)

        # Verify server state was potentially updated
        current_state = Server.get_state(pid)
        # State should be valid (it may or may not have changed phase)
        assert %GameStateType{} = current_state
      end
    end

    test "does not update server state on error" do
      {:ok, pid} = Server.start_link()
      initial_state = Server.get_state(pid)

      # Try invalid action
      {:error, _reason} = Server.apply_action(pid, :north, {:bid, 10})

      # Verify state unchanged
      current_state = Server.get_state(pid)
      assert current_state.phase == initial_state.phase
    end
  end

  describe "legal_actions/2" do
    test "returns list of actions" do
      {:ok, pid} = Server.start_link()
      actions = Server.legal_actions(pid, :north)
      assert is_list(actions)
    end

    test "legal actions depend on game state" do
      {:ok, pid} = Server.start_link()
      # Different positions may have different legal actions
      actions_north = Server.legal_actions(pid, :north)
      actions_east = Server.legal_actions(pid, :east)
      # Both should be lists
      assert is_list(actions_north)
      assert is_list(actions_east)
    end
  end

  describe "game_over?/1" do
    test "returns false for new game" do
      {:ok, pid} = Server.start_link()
      refute Server.game_over?(pid)
    end

    test "returns true when game is complete" do
      {:ok, pid} = Server.start_link()

      # Fast-forward to complete state
      complete_state = %GameStateType{
        GameState.new(seed: 1)
        | phase: :complete,
          winner: :north_south
      }

      :sys.replace_state(pid, fn state -> %{state | game_state: complete_state} end)

      assert Server.game_over?(pid)
    end
  end

  describe "winner/1" do
    test "returns error when game is not over" do
      {:ok, pid} = Server.start_link()
      assert {:error, _reason} = Server.winner(pid)
    end

    test "returns winner when game is complete" do
      {:ok, pid} = Server.start_link()

      # Set to complete state with winner
      complete_state = %GameStateType{
        GameState.new(seed: 1)
        | phase: :complete,
          winner: :north_south
      }

      :sys.replace_state(pid, fn state -> %{state | game_state: complete_state} end)

      assert {:ok, :north_south} = Server.winner(pid)
    end
  end

  describe "get_history/1" do
    test "returns list of events" do
      {:ok, pid} = Server.start_link()
      events = Server.get_history(pid)
      assert is_list(events)
    end

    test "history grows after actions are applied" do
      {:ok, pid} = Server.start_link()
      initial_events = Server.get_history(pid)
      initial_count = length(initial_events)

      # Try to apply a legal action
      actions = Server.legal_actions(pid, :north)

      if length(actions) > 0 do
        action = hd(actions)
        {:ok, _state} = Server.apply_action(pid, :north, action)

        new_events = Server.get_history(pid)
        new_count = length(new_events)
        # History may have grown
        assert new_count >= initial_count
      end
    end
  end

  describe "reset/1" do
    test "resets game to initial state" do
      {:ok, pid} = Server.start_link()

      # Make some legal moves if possible
      actions = Server.legal_actions(pid, :north)

      if length(actions) > 0 do
        action = hd(actions)
        {:ok, _state} = Server.apply_action(pid, :north, action)
      end

      # Reset
      assert :ok = Server.reset(pid)

      # Verify reset
      state = Server.get_state(pid)
      assert state.phase == :dealer_selection
      assert state.hand_number == 1
    end

    test "returns to initial state" do
      {:ok, pid} = Server.start_link()

      # Reset should work regardless of state
      assert :ok = Server.reset(pid)

      # Verify we're in initial state
      state = Server.get_state(pid)
      assert %GameStateType{} = state
      assert state.phase == :dealer_selection
    end
  end

  describe "chance boundary" do
    test "two fresh servers deal different first hands" do
      assert first_hands(start_and_deal()) != first_hands(start_and_deal())
    end

    test "a seeded server deals the same first hand every time" do
      assert first_hands(start_and_deal(seed: 7)) == first_hands(start_and_deal(seed: 7))
    end

    test "a seed does not leak into an explicitly supplied state" do
      supplied = GameState.new(seed: 99)

      {:ok, pid} = Server.start_link(initial_state: supplied, seed: 7)

      assert Server.get_state(pid).chance == supplied.chance
    end

    test "reset reproduces the game on a seeded server" do
      {:ok, pid} = Server.start_link(seed: 7)

      {:ok, _} = Server.apply_action(pid, :north, :select_dealer)
      before_reset = Server.get_state(pid)

      :ok = Server.reset(pid)
      {:ok, _} = Server.apply_action(pid, :north, :select_dealer)

      assert Server.get_state(pid).deck == before_reset.deck
      assert Server.get_state(pid).dealer_selection_cuts == before_reset.dealer_selection_cuts
    end

    test "reset starts a different game on an unseeded server" do
      {:ok, pid} = Server.start_link()

      {:ok, _} = Server.apply_action(pid, :north, :select_dealer)
      before_reset = Server.get_state(pid)

      :ok = Server.reset(pid)
      {:ok, _} = Server.apply_action(pid, :north, :select_dealer)

      assert Server.get_state(pid).deck != before_reset.deck
    end

    test "the engine ignores what the calling process has drawn from :rand" do
      :rand.seed(:exsss, {1, 2, 3})
      {:ok, pid} = Server.start_link(seed: 7)
      {:ok, _} = Server.apply_action(pid, :north, :select_dealer)
      seeded_caller = Server.get_state(pid).deck

      :rand.seed(:exsss, {9, 9, 9})
      _ = Enum.shuffle(1..100)
      {:ok, other_pid} = Server.start_link(seed: 7)
      {:ok, _} = Server.apply_action(other_pid, :north, :select_dealer)

      assert Server.get_state(other_pid).deck == seeded_caller
    end
  end

  describe "process isolation" do
    test "multiple servers maintain independent state" do
      {:ok, pid1} = Server.start_link(game_id: "game1")
      {:ok, pid2} = Server.start_link(game_id: "game2")

      # Get initial state of second game
      state2_before = Server.get_state(pid2)

      # Try to advance first game
      actions = Server.legal_actions(pid1, :north)

      if length(actions) > 0 do
        action = hd(actions)
        {:ok, _state} = Server.apply_action(pid1, :north, action)
      end

      # Verify second game unchanged
      state2_after = Server.get_state(pid2)
      assert state2_after.phase == state2_before.phase
      assert state2_after.hand_number == state2_before.hand_number
    end

    test "server crash does not affect other servers" do
      # Trap exits so we don't crash the test process
      Process.flag(:trap_exit, true)

      {:ok, pid1} = Server.start_link()
      {:ok, pid2} = Server.start_link()

      # Kill first server
      Process.exit(pid1, :kill)

      # Wait for exit message
      receive do
        {:EXIT, ^pid1, :killed} -> :ok
      after
        100 -> :ok
      end

      refute Process.alive?(pid1)

      # Verify second server still works
      assert Process.alive?(pid2)
      state = Server.get_state(pid2)
      assert %GameStateType{} = state
    end
  end

  # Starts a server, runs the cut ceremony, and waits out the presentation
  # window so the first hand is actually dealt.
  defp start_and_deal(opts \\ []) do
    {:ok, pid} = Server.start_link(Keyword.put_new(opts, :dealer_selection_delay_ms, 20))
    {:ok, _cut_state} = Server.apply_action(pid, :north, :select_dealer)
    Process.sleep(80)

    state = Server.get_state(pid)
    assert state.phase == :bidding, "expected the dealer-selection window to have elapsed"
    state
  end

  defp first_hands(state) do
    Map.new(state.players, fn {position, player} -> {position, player.hand} end)
  end
end
