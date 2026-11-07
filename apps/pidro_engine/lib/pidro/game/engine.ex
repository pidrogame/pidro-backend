defmodule Pidro.Game.Engine do
  @moduledoc """
  Core API for the Pidro game engine.

  This module provides the main interface for game state management and action
  processing. It serves as the primary entry point for all game logic, coordinating
  between phase-specific modules and maintaining game state consistency.

  ## Architecture

  The engine follows a functional, immutable design:
  - All functions are pure (same inputs -> same outputs)
  - State is immutable; operations return new state
  - Uses pattern matching on {phase, action} pairs
  - Delegates to phase-specific modules for complex logic

  ## Core Functions

  - `apply_action/3` - Process an action and update state
  - `legal_actions/2` - Get valid actions for a position
  - `game_over?/1` - Check if game is complete
  - `winner/1` - Get winning team (if game is over)

  ## Usage

      # Create initial game state
      state = GameState.new(seed: 7)

      # Apply an action
      {:ok, new_state} = Engine.apply_action(state, :north, {:bid, 10})

      # Check valid actions
      actions = Engine.legal_actions(new_state, :east)

      # Check game status
      if Engine.game_over?(new_state) do
        {:ok, winning_team} = Engine.winner(new_state)
        IO.puts("Game over! Winner: \#{winning_team}")
      end

  ## Error Handling

  All operations return `{:ok, result}` or `{:error, reason}` tuples.
  Use the `Pidro.Game.Errors` module to format error messages.

  ## Phase Coordination

  The engine coordinates with these phase-specific modules (to be implemented):
  - `Pidro.Game.Phases.DealerSelection` - Dealer selection logic
  - `Pidro.Game.Phases.Dealing` - Card dealing logic
  - `Pidro.Game.Phases.Bidding` - Bidding logic
  - `Pidro.Game.Phases.Declaring` - Trump declaration logic
  - `Pidro.Game.Phases.Discarding` - Discard logic
  - `Pidro.Game.Phases.SecondDeal` - Second deal logic
  - `Pidro.Game.Phases.Playing` - Trick-taking logic
  - `Pidro.Game.Phases.Scoring` - Scoring logic
  """

  alias Pidro.Core.Types
  alias Pidro.Core.Types.Player
  alias Pidro.Core.{Card, Chance, Deck, GameState}
  alias Pidro.Game.{Errors, StateMachine}

  # Phase-specific modules
  alias Pidro.Game.{Dealing, Bidding, Trump, Discard, Play, DealerRob}
  alias Pidro.Finnish.Scorer

  # =============================================================================
  # Core API - Action Processing
  # =============================================================================

  @doc """
  Applies an action to the game state and returns the new state.

  This is the primary state transition function. It validates the action,
  verifies it's legal for the current phase and position, then delegates
  to the appropriate phase-specific module to process the action.

  ## Parameters

  - `state` - The current game state
  - `position` - The position of the player making the action
  - `action` - The action to perform

  ## Returns

  - `{:ok, new_state}` if the action was successfully applied
  - `{:error, reason}` if the action is invalid or cannot be performed

  ## Examples

      # Make a bid during bidding phase
      {:ok, new_state} = apply_action(state, :north, {:bid, 10})

      # Pass during bidding
      {:ok, new_state} = apply_action(state, :east, :pass)

      # Play a card during playing phase
      {:ok, new_state} = apply_action(state, :south, {:play_card, {14, :hearts}})

      # Invalid action returns error
      {:error, :invalid_phase} = apply_action(state, :north, {:bid, 10})
      # (when not in bidding phase)

  ## Error Cases

  - `:game_already_complete` - Game has ended
  - `:not_your_turn` - Action attempted by wrong player
  - `:invalid_phase` - Action not valid for current phase
  - `:player_eliminated` - Player has gone cold
  - Phase-specific errors - See individual phase modules
  """
  @spec apply_action(Types.GameState.t(), Types.position(), Types.action()) ::
          {:ok, Types.GameState.t()} | {:error, Errors.error()}
  def apply_action(%Types.GameState{phase: :complete}, _position, _action) do
    Errors.error(:game_already_complete)
  end

  def apply_action(%Types.GameState{} = state, position, action) do
    with {:ok, position} <- Errors.validate_position(position),
         :ok <- validate_player_not_eliminated(state, position),
         :ok <- validate_turn(state, position, action),
         {:ok, new_state} <- dispatch_action(state, position, action),
         {:ok, final_state} <- maybe_auto_transition(new_state) do
      {:ok, final_state}
    end
  end

  # =============================================================================
  # Core API - Legal Actions
  # =============================================================================

  @doc """
  Returns a list of valid actions for a given position.

  This function analyzes the current game state and phase to determine which
  actions are legal for the specified position. It's useful for AI players,
  UI hints, and validation.

  ## Parameters

  - `state` - The current game state
  - `position` - The position to check legal actions for

  ## Returns

  A list of valid actions that the position can perform. Returns an empty list
  if no actions are available (not their turn, eliminated, etc.).

  ## Examples

      # During bidding
      actions = legal_actions(state, :north)
      # => [{:bid, 6}, {:bid, 7}, ..., {:bid, 14}, :pass]

      # Not their turn
      actions = legal_actions(state, :east)
      # => []

      # During playing phase with trump cards
      actions = legal_actions(state, :south)
      # => [{:play_card, {14, :hearts}}, {:play_card, {13, :hearts}}, ...]

  ## Performance

  This function may be called frequently (especially for AI), so it's designed
  to be efficient. Complex validation is deferred to `apply_action/3`.
  """
  @spec legal_actions(Types.GameState.t(), Types.position()) :: [Types.action()]
  def legal_actions(%Types.GameState{phase: :complete}, _position), do: []

  def legal_actions(%Types.GameState{} = state, position) do
    with {:ok, position} <- Errors.validate_position(position),
         true <- not player_eliminated?(state, position),
         true <- is_players_turn?(state, position, state.phase) do
      get_legal_actions_for_phase(state, position)
    else
      _ -> []
    end
  end

  # =============================================================================
  # Core API - Game Status
  # =============================================================================

  @doc """
  Checks if the game is over.

  A game is over when the phase is `:complete`, which occurs when one team
  has reached or exceeded the winning score (default: 62 points).

  ## Parameters

  - `state` - The current game state

  ## Returns

  `true` if the game is complete, `false` otherwise.

  ## Examples

      iex> game_over?(%GameState{phase: :complete})
      true

      iex> game_over?(%GameState{phase: :playing})
      false
  """
  @spec game_over?(Types.GameState.t()) :: boolean()
  def game_over?(%Types.GameState{phase: :complete}), do: true
  def game_over?(%Types.GameState{}), do: false

  @doc """
  Returns the winning team if the game is over.

  ## Parameters

  - `state` - The current game state

  ## Returns

  - `{:ok, team}` if the game is complete and there's a winner
  - `{:error, :game_not_complete}` if the game is still in progress

  ## Examples

      iex> state = %GameState{phase: :complete, winner: :north_south}
      iex> winner(state)
      {:ok, :north_south}

      iex> state = %GameState{phase: :playing}
      iex> winner(state)
      {:error, :game_not_complete}

  ## Note

  The winner is determined during the scoring phase and stored in the state.
  This function simply retrieves that value; it does not calculate the winner.
  """
  @spec winner(Types.GameState.t()) :: {:ok, Types.team()} | {:error, atom()}
  def winner(%Types.GameState{phase: :complete, winner: winner}) when winner != nil do
    {:ok, winner}
  end

  def winner(%Types.GameState{phase: :complete, winner: nil}) do
    # Should not happen, but handle gracefully
    {:error, :no_winner_determined}
  end

  def winner(%Types.GameState{}) do
    {:error, :game_not_complete}
  end

  @doc """
  Advances the game past the dealer selection ceremony.

  Called by the Server (GenServer) after a display delay, to resume the
  auto-transition chain from dealer_selection → dealing → bidding.

  Only valid when the phase is `:dealer_selection` and cuts have been populated.

  ## Returns

  - `{:ok, new_state}` — state after auto-transitioning through dealing
  - `{:error, :not_in_dealer_selection}` — phase is not dealer_selection
  """
  @spec advance_from_dealer_selection(Types.GameState.t()) ::
          {:ok, Types.GameState.t()} | {:error, atom()}
  def advance_from_dealer_selection(
        %Types.GameState{phase: :dealer_selection, dealer_selection_cuts: cuts} = state
      )
      when not is_nil(cuts) do
    state
    |> Map.put(:phase, :dealing)
    |> maybe_auto_transition()
  end

  def advance_from_dealer_selection(_state), do: {:error, :not_in_dealer_selection}

  @doc """
  Deals the next hand after a held hand result. Other phases are unchanged.

  The caller decides when to continue; scoring and the next deal remain engine work.

      {:ok, next_hand} = Engine.continue_hand(held_state)
  """
  @spec continue_hand(Types.GameState.t()) :: {:ok, Types.GameState.t()} | {:error, atom()}
  def continue_hand(%Types.GameState{phase: :hand_complete} = state), do: start_next_hand(state)
  def continue_hand(%Types.GameState{} = state), do: {:ok, state}

  @doc """
  Ends a settled hand (`Play.settled_play/1`) in one step: the lone trump
  holder lays their trumps down, highest first. Records
  `{:hand_settled, holder, cards}`, then plays each card exactly as if tapped,
  as a one-card trick, which completes the hand; `last_hand.settled` names the
  holder and the cards.

  Any other state, Louisiana's included, is `{:error, :not_settled}`, so the
  caller has nothing to commit.

      {:ok, scored} = Engine.settle_hand(settled_state)
  """
  @spec settle_hand(Types.GameState.t()) :: {:ok, Types.GameState.t()} | {:error, :not_settled}
  def settle_hand(%Types.GameState{} = state) do
    case Play.settled_play(state) do
      {holder, _card} -> apply_action(state, holder, :claim_remaining)
      nil -> {:error, :not_settled}
    end
  end

  # =============================================================================
  # Action Dispatching
  # =============================================================================

  # Dispatches actions to phase-specific handlers based on current phase
  # Pattern matches on {phase, action} pairs for efficient routing

  # Dealer Selection Phase
  # Note: Dealer selection is typically automatic via Dealing.select_dealer
  # This action is included for completeness but may not be used in practice
  defp dispatch_action(
         %Types.GameState{phase: :dealer_selection, dealer_selection_cuts: nil} = state,
         _position,
         :select_dealer
       ) do
    Dealing.select_dealer(state)
  end

  defp dispatch_action(
         %Types.GameState{phase: :dealer_selection} = state,
         _position,
         :select_dealer
       ) do
    Errors.error({:invalid_action, :select_dealer, state.phase})
  end

  defp dispatch_action(
         %Types.GameState{phase: :dealer_selection, dealer_selection_cuts: nil} = state,
         _position,
         {:cut_deck, _pos}
       ) do
    # For now, dealer selection is handled automatically
    # This could be extended to support manual dealer selection
    Dealing.select_dealer(state)
  end

  defp dispatch_action(
         %Types.GameState{phase: :dealer_selection} = state,
         _position,
         {:cut_deck, _pos}
       ) do
    Errors.error({:invalid_action, :cut_deck, state.phase})
  end

  # Bidding Phase
  defp dispatch_action(%Types.GameState{phase: :bidding} = state, position, {:bid, amount}) do
    Bidding.apply_bid(state, position, amount)
  end

  defp dispatch_action(%Types.GameState{phase: :bidding} = state, position, :pass) do
    Bidding.apply_pass(state, position)
  end

  # Declaring Phase
  defp dispatch_action(
         %Types.GameState{phase: :declaring} = state,
         _position,
         {:declare_trump, suit}
       ) do
    Trump.declare_trump(state, suit)
  end

  # Discarding Phase
  # Note: Discarding is automatic in Finnish Pidro (all non-trumps are discarded)
  # This is handled by the state machine transition, not by player action
  defp dispatch_action(
         %Types.GameState{phase: :discarding} = _state,
         _position,
         {:discard, _cards}
       ) do
    # Discarding is automatic, players don't manually discard
    {:error, {:invalid_action, :discard, :discarding}}
  end

  # Second Deal Phase
  # Only the dealer can rob the pack during second_deal
  defp dispatch_action(
         %Types.GameState{phase: :second_deal} = state,
         _position,
         {:select_hand, cards}
       ) do
    Discard.dealer_rob_pack(state, cards)
  end

  # Playing Phase
  defp dispatch_action(%Types.GameState{phase: :playing} = state, position, {:play_card, card}) do
    Play.play_card(state, position, card)
  end

  # Meta Actions (available in multiple phases)
  defp dispatch_action(%Types.GameState{} = _state, _position, :resign) do
    # TODO: Implement resignation logic
    # Immediately end game, opposing team wins
    {:error, :not_implemented}
  end

  # Only a settled hand's holder can claim, and they win every remaining trick.
  defp dispatch_action(%Types.GameState{phase: :playing} = state, position, :claim_remaining) do
    with {^position, _card} <- Play.settled_play(state) do
      trump = state.trump_suit

      cards =
        state
        |> Play.legal_plays(position)
        |> Enum.sort(&(Card.compare(&1, &2, trump) != :lt))

      state =
        Enum.reduce(cards, record_event(state, {:hand_settled, position, cards}), fn card, acc ->
          {:ok, acc} = apply_action(acc, position, {:play_card, card})
          acc
        end)

      {:ok, put_in(state.last_hand[:settled], %{position: position, cards: cards})}
    else
      _ -> {:error, :not_settled}
    end
  end

  # Invalid action for current phase
  defp dispatch_action(%Types.GameState{phase: phase}, _position, action) do
    Errors.error({:invalid_action, action, phase})
  end

  # =============================================================================
  # Event Recording
  # =============================================================================

  # Records an event in the game state's event history.
  #
  # This function creates an event tuple from the given type and data,
  # then appends it to the state's events list. Events are used for
  # event sourcing, replay, and state reconstruction.
  @spec record_event(Types.GameState.t(), Types.event()) :: Types.GameState.t()
  defp record_event(%Types.GameState{} = state, event) do
    %{state | events: state.events ++ [event]}
  end

  # =============================================================================
  # Legal Actions by Phase
  # =============================================================================

  # Returns legal actions for the current phase
  # Called by legal_actions/2 after basic validation

  defp get_legal_actions_for_phase(
         %Types.GameState{phase: :dealer_selection, dealer_selection_cuts: nil},
         _position
       ) do
    # Any player can trigger dealer selection
    [:select_dealer]
  end

  defp get_legal_actions_for_phase(%Types.GameState{phase: :dealer_selection}, _position) do
    []
  end

  defp get_legal_actions_for_phase(%Types.GameState{phase: :dealing}, _position) do
    # Dealing is automatic, no player actions
    []
  end

  defp get_legal_actions_for_phase(%Types.GameState{phase: :bidding} = state, position) do
    # Delegate to Bidding module which handles all validation logic
    Bidding.legal_actions(state, position)
  end

  defp get_legal_actions_for_phase(%Types.GameState{phase: :declaring} = state, position) do
    # Only the bid winner can declare trump
    if position == elem(state.highest_bid || {:none, 0}, 0) do
      # Return all four suits as valid trump declarations
      Enum.map(Types.all_suits(), &{:declare_trump, &1})
    else
      []
    end
  end

  defp get_legal_actions_for_phase(%Types.GameState{phase: :discarding} = _state, _position) do
    # Discarding is automatic in Finnish Pidro, no player actions needed
    []
  end

  defp get_legal_actions_for_phase(%Types.GameState{phase: :second_deal} = state, position) do
    # Only dealer can rob the pack if there are remaining cards
    if position == state.current_dealer and length(state.deck) > 0 do
      # Dealer needs to select 6 cards from their hand + remaining deck
      # This is complex to enumerate all possibilities, so we return a generic action marker
      # The actual validation happens in Discard.dealer_rob_pack
      [{:select_hand, :choose_6_cards}]
    else
      # Not dealer's turn or no cards to rob, second deal happens automatically
      []
    end
  end

  defp get_legal_actions_for_phase(%Types.GameState{phase: :playing} = state, position) do
    # Return valid card plays (only trump cards can be played in Finnish Pidro)
    player = state.players[position]

    if player && state.trump_suit && not player.eliminated? do
      Enum.map(Play.legal_plays(state, position), &{:play_card, &1})
    else
      []
    end
  end

  defp get_legal_actions_for_phase(%Types.GameState{phase: :scoring}, _position) do
    # Scoring is automatic, no player actions
    []
  end

  defp get_legal_actions_for_phase(%Types.GameState{phase: :hand_complete}, _position) do
    # No ordinary player actions while the hand result is held.
    []
  end

  # =============================================================================
  # Validation Helpers
  # =============================================================================

  # Validates that the player is not eliminated (gone cold)
  @spec validate_player_not_eliminated(Types.GameState.t(), Types.position()) ::
          :ok | {:error, Errors.error()}
  defp validate_player_not_eliminated(%Types.GameState{players: players}, position) do
    case Map.get(players, position) do
      %Player{eliminated?: true} ->
        Errors.error({:player_eliminated, position})

      %Player{eliminated?: false} ->
        :ok

      nil ->
        Errors.error({:invalid_position, position})
    end
  end

  # Validates that it's the player's turn (when turn-based)
  @spec validate_turn(Types.GameState.t(), Types.position(), Types.action()) ::
          :ok | {:error, Errors.error()}
  defp validate_turn(%Types.GameState{} = state, position, _action) do
    if is_players_turn?(state, position, state.phase) do
      :ok
    else
      Errors.error({:not_your_turn, state.current_turn})
    end
  end

  # Checks if it's the player's turn for the current phase
  @spec is_players_turn?(Types.GameState.t(), Types.position(), Types.phase()) :: boolean()
  defp is_players_turn?(%Types.GameState{}, _position, :dealer_selection) do
    # Dealer selection is not turn-based - any player can trigger it
    true
  end

  defp is_players_turn?(%Types.GameState{current_turn: nil}, _position, phase)
       when phase in [:dealing, :scoring, :complete] do
    # These phases don't have turn-based actions
    false
  end

  defp is_players_turn?(%Types.GameState{current_turn: current}, position, _phase) do
    current == position
  end

  # =============================================================================
  # Phase Transition Helpers
  # =============================================================================

  # Automatically transitions to next phase if conditions are met
  # Also handles automatic phase operations (dealing, discarding, second_deal, scoring)
  @spec maybe_auto_transition(Types.GameState.t()) :: {:ok, Types.GameState.t()}
  defp maybe_auto_transition(%Types.GameState{} = state) do
    # Always handle automatic operations for automatic phases
    # Each handler decides whether to transition and recurse
    handle_automatic_phase(state)
  end

  # Handles automatic operations for phases that don't require player input
  @spec handle_automatic_phase(Types.GameState.t()) :: {:ok, Types.GameState.t()}
  defp handle_automatic_phase(%Types.GameState{phase: :dealing} = state) do
    # Automatically deal initial cards
    case Dealing.deal_initial(state) do
      {:ok, new_state} ->
        # Transition to bidding phase
        transitioned_state = %{new_state | phase: :bidding}
        # Then check if we can auto-transition from bidding (we can't - bidding is manual)
        maybe_auto_transition(transitioned_state)

      error ->
        error
    end
  end

  defp handle_automatic_phase(%Types.GameState{phase: :discarding} = state) do
    # Automatically discard all non-trump cards
    case Discard.discard_non_trumps(state) do
      {:ok, new_state} ->
        # Transition to second_deal phase
        transitioned_state = %{new_state | phase: :second_deal}
        # Then handle the second_deal phase
        maybe_auto_transition(transitioned_state)

      error ->
        error
    end
  end

  defp handle_automatic_phase(%Types.GameState{phase: :second_deal} = state) do
    # CRITICAL: Must ALWAYS call second_deal/1 first to distribute cards to non-dealers
    #
    # Historical bug: Previously, when auto_dealer_rob: true, code jumped directly
    # to dealer_rob_pack/2, which only updates the dealer's hand. This left non-dealer
    # players with their post-discard trump-only hands (0-9 cards instead of 6).
    #
    # Fix: Always call second_deal/1 first. It handles:
    # 1. Dealing cards to non-dealers to reach 6 cards each
    # 2. Determining if dealer needs to rob (checks remaining deck)
    # 3. Staying in :second_deal phase if rob needed, or transitioning to :playing if not
    #
    # Then, based on the resulting phase and auto_rob config, either:
    # - Auto-select best cards for dealer (auto mode)
    # - Wait for dealer to manually select (manual mode)
    # - Transition to playing (if no rob needed)

    case Discard.second_deal(state) do
      {:ok, new_state} ->
        # STEP 2: Check if dealer needs to rob the pack
        # second_deal/1 returns phase: :second_deal if dealer needs to rob (deck has cards)
        # or phase: :playing if dealer doesn't need to rob (deck empty or dealer has 6 cards)

        if new_state.phase == :second_deal do
          # Dealer needs to rob - check if auto mode is enabled
          auto_rob = Map.get(new_state.config, :auto_dealer_rob, true)

          if auto_rob do
            # Auto mode: automatically select best 6 cards for dealer
            dealer = new_state.current_dealer
            dealer_player = Map.get(new_state.players, dealer)
            pool = dealer_player.hand ++ new_state.deck
            selected_cards = DealerRob.select_best_cards(pool, new_state.trump_suit)

            case Discard.dealer_rob_pack(new_state, selected_cards) do
              {:ok, final_state} ->
                maybe_auto_transition(final_state)

              error ->
                error
            end
          else
            # Manual mode: second_deal already set turn to dealer, just return state
            # Dealer will manually select cards via dealer_rob action
            {:ok, new_state}
          end
        else
          # second_deal already transitioned to :playing phase (no rob needed)
          # This happens when deck is empty or dealer already has 6 cards
          maybe_auto_transition(new_state)
        end

      error ->
        error
    end
  end

  defp handle_automatic_phase(%Types.GameState{phase: :playing} = state) do
    # Compute kills at the start of (and during) the playing phase
    # This determines which players have been eliminated in this round
    kill_state = Play.compute_kills(state)

    # After computing kills, check if we can auto-transition to scoring
    if can_auto_transition?(kill_state) do
      case StateMachine.next_phase(kill_state.phase, kill_state) do
        {:error, _reason} ->
          # If StateMachine can't determine a next phase, just stay in playing
          {:ok, kill_state}

        next_phase when is_atom(next_phase) ->
          # Transition to next phase and let maybe_auto_transition/1
          # handle any further automatic work (e.g., scoring)
          new_state = %{kill_state | phase: next_phase}
          maybe_auto_transition(new_state)
      end
    else
      # Hands not empty / not ready to score yet: stay in playing with kills applied
      {:ok, kill_state}
    end
  end

  defp handle_automatic_phase(%Types.GameState{phase: :scoring} = state) do
    # Automatically score the hand using Finnish Pidro rules
    scored_state = score_hand(state)

    case Scorer.determine_winner(scored_state) do
      {:ok, winner} ->
        # Get winning team's score
        winning_score = Map.get(scored_state.cumulative_scores, winner, 0)

        # Game over, set winner and transition to complete
        final_state =
          scored_state
          |> GameState.update(:winner, winner)
          |> GameState.update(:phase, :complete)
          |> record_event({:game_won, winner, winning_score})

        {:ok, final_state}

      {:error, :game_not_over} ->
        # Game not over, transition to hand_complete
        transitioned_state = %{scored_state | phase: :hand_complete}
        maybe_auto_transition(transitioned_state)
    end
  end

  defp handle_automatic_phase(
         %Types.GameState{phase: :hand_complete, config: %{pace: :own}} = state
       ),
       do: {:ok, state}

  defp handle_automatic_phase(%Types.GameState{phase: :hand_complete} = state),
    do: start_next_hand(state)

  # Non-automatic phases: check if we can transition to next phase
  defp handle_automatic_phase(%Types.GameState{} = state) do
    if can_auto_transition?(state) do
      next_phase = StateMachine.next_phase(state.phase, state)

      # Transition to the next phase and recursively handle automatic work
      # such as dealing after dealer selection.
      new_state = %{state | phase: next_phase}
      maybe_auto_transition(new_state)
    else
      {:ok, state}
    end
  end

  defp start_next_hand(state) do
    # Rotate dealer and prepare for next hand
    case Dealing.rotate_dealer(state) do
      {:ok, new_state} ->
        # Shuffle the next hand's deck from this game's chance stream. The
        # dealer-cut ceremony runs once per game, so for hands 2..N this is the
        # deck that is actually dealt.
        {new_deck, chance} = Chance.shuffle(Deck.ordered(), new_state.chance)

        # Reset hand-specific state for new hand
        reset_state =
          new_state
          |> GameState.update(:deck, new_deck)
          |> GameState.update(:chance, chance)
          |> GameState.update(:highest_bid, nil)
          |> GameState.update(:bidding_team, nil)
          |> GameState.update(:trump_suit, nil)
          |> GameState.update(:bids, [])
          |> GameState.update(:tricks, [])
          |> GameState.update(:current_trick, nil)
          |> GameState.update(:trick_number, 0)
          |> GameState.update(:hand_points, %{north_south: 0, east_west: 0})
          |> GameState.update(:discarded_cards, [])
          |> GameState.update(:killed_cards, %{})
          |> GameState.update(:cards_requested, %{})
          |> GameState.update(:dealer_pool_size, nil)
          |> GameState.update(:dealer_selection_cuts, nil)

        # Reset player hands and elimination status
        # Iterate over new_state.players to ensure any changes from rotate_dealer are preserved
        reset_players =
          Enum.reduce(new_state.players, new_state.players, fn {pos, player}, acc ->
            Map.put(acc, pos, %{
              player
              | hand: [],
                eliminated?: false,
                revealed_cards: [],
                tricks_won: 0
            })
          end)

        final_state = GameState.update(reset_state, :players, reset_players)

        # Transition to dealer_selection for new hand
        transitioned_state = %{final_state | phase: :dealer_selection}
        maybe_auto_transition(transitioned_state)

      error ->
        error
    end
  end

  # Checks if the current phase should automatically transition
  @spec can_auto_transition?(Types.GameState.t()) :: boolean()
  defp can_auto_transition?(%Types.GameState{phase: :dealer_selection} = state) do
    # Once cuts are populated, pause so the frontend can display the ceremony.
    # The Server (GenServer) schedules a timer to continue the transition.
    is_nil(state.dealer_selection_cuts) and
      StateMachine.can_transition_from_dealer_selection?(state)
  end

  defp can_auto_transition?(%Types.GameState{phase: :dealing} = state) do
    StateMachine.can_transition_from_dealing?(state)
  end

  defp can_auto_transition?(%Types.GameState{phase: :bidding}) do
    # Bidding phase manages its own transitions via Bidding.finalize_bidding/1
    # Do not auto-transition here
    false
  end

  defp can_auto_transition?(%Types.GameState{phase: :declaring} = state) do
    StateMachine.can_transition_from_declaring?(state)
  end

  defp can_auto_transition?(%Types.GameState{phase: :discarding} = state) do
    StateMachine.can_transition_from_discarding?(state)
  end

  defp can_auto_transition?(%Types.GameState{phase: :second_deal} = state) do
    StateMachine.can_transition_from_second_deal?(state)
  end

  defp can_auto_transition?(%Types.GameState{phase: :playing} = state) do
    StateMachine.can_transition_from_playing?(state)
  end

  defp can_auto_transition?(%Types.GameState{phase: :scoring} = state) do
    StateMachine.can_transition_from_scoring?(state)
  end

  defp can_auto_transition?(%Types.GameState{phase: :hand_complete} = state) do
    StateMachine.can_transition_from_hand_complete?(state)
  end

  defp can_auto_transition?(%Types.GameState{phase: :complete}) do
    # Terminal state, never auto-transition
    false
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  # Scores the hand: calculates trick points, updates hand scores, and applies bid results
  @spec score_hand(Types.GameState.t()) :: Types.GameState.t()
  defp score_hand(%Types.GameState{} = state) do
    scored_tricks =
      Enum.map(state.tricks, &Scorer.score_trick(&1, state.trump_suit, state.variant))

    hand_points = Scorer.aggregate_team_scores(scored_tricks)

    state
    |> GameState.update(:hand_points, hand_points)
    |> Scorer.apply_bid_result()
  end

  # Checks if a player is eliminated
  @spec player_eliminated?(Types.GameState.t(), Types.position()) :: boolean()
  defp player_eliminated?(%Types.GameState{players: players}, position) do
    case Map.get(players, position) do
      %Player{eliminated?: true} -> true
      _ -> false
    end
  end
end
