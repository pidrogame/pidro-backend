defmodule Pidro.Game.Play do
  @moduledoc """
  Card playing and trick management for the Finnish Pidro variant.

  This module handles all aspects of the playing phase, including:
  - Playing cards from a player's hand
  - Validating card plays (must be trump in Finnish variant)
  - Completing tricks and determining winners
  - Eliminating players who go "cold" (run out of trumps)
  - Revealing non-trump cards when a player goes cold
  - Managing trick leadership and turn rotation

  ## Finnish Pidro Playing Rules

  ### Card Playing
  - Only trump cards can be played (non-trumps are "camouflage")
  - Players must play a trump card if they have one
  - The highest trump card wins the trick
  - The trick winner leads the next trick

  ### Going "Cold"
  - A player whose turn comes with no trump to play goes "cold" (eliminated)
    there and then, and the turn moves on; playing a last trump does not
  - Their remaining non-trump cards are revealed to all players
  - They no longer participate in the remaining tricks
  - Their team can still win points through their partner

  ### Trick Completion
  - A trick is complete when all non-eliminated players have played
  - Points are awarded to the winning team based on card values
  - The trick winner leads the next trick

  ## Examples

      # Play a card from a player's hand
      iex> state = %GameState{phase: :playing, trump_suit: :hearts, current_turn: :north}
      iex> {:ok, state} = Play.play_card(state, :north, {14, :hearts})
      iex> length(state.current_trick.plays)
      1

      # Complete a trick
      iex> trick = %Trick{plays: [{:north, {14, :hearts}}, {:east, {10, :hearts}}], ...}
      iex> {:ok, winner, points} = Play.complete_trick(trick)
      iex> winner
      :north
      iex> points
      2

      # Eliminate a player who runs out of trumps
      iex> state = %GameState{trump_suit: :hearts}
      iex> player = %Player{hand: [{10, :clubs}, {7, :spades}]}
      iex> {:ok, state} = Play.eliminate_player(state, :north)
      iex> state.players[:north].eliminated?
      true
  """

  alias Pidro.Core.{Types, Card, GameState}
  alias Pidro.Core.Types.{Player, Trick}
  alias Pidro.Game.{Errors, Trump}

  @type game_state :: Types.GameState.t()
  @type position :: Types.position()
  @type card :: Types.card()
  @type suit :: Types.suit()
  @type error :: Errors.error()

  # =============================================================================
  # Kill Rule (Redeal)
  # =============================================================================

  @doc """
  Compute killed cards for all players entering playing phase.

  Players with >6 trump must kill down to 6 using their lowest non-point cards.
  If a player has 7+ point cards, they cannot kill and keep all their cards.

  ## Parameters
  - `state` - Current game state with players' hands set

  ## Returns
  Updated game state with killed cards removed from hands and stored in state.killed_cards

  ## State Changes
  - Updates `killed_cards` map with {position => [cards]} entries
  - Removes killed cards from players' hands
  - Records `{:cards_killed, killed_map}` event

  ## Examples

      iex> player = %Player{hand: [{7, :h}, {6, :h}, {4, :h}, {3, :h}, {2, :h}, {14, :h}, {11, :h}]}
      iex> state = %GameState{trump_suit: :hearts, players: %{north: player}}
      iex> state = Play.compute_kills(state)
      iex> length(state.players[:north].hand)
      6
  """
  @spec compute_kills(game_state()) :: game_state()
  def compute_kills(%Types.GameState{players: players, trump_suit: trump} = state) do
    killed_cards =
      players
      |> Enum.reduce(%{}, fn {pos, player}, acc ->
        hand_size = length(player.hand)

        if hand_size > 6 do
          # Must kill excess cards
          excess = hand_size - 6
          non_point = Card.non_point_trumps(player.hand, trump)

          if length(non_point) >= excess do
            # Kill the lowest non-point trumps, as a player at the table would.
            # Fives are point cards, so these share the trump suit and sort by rank.
            to_kill = non_point |> Enum.sort() |> Enum.take(excess)
            Map.put(acc, pos, to_kill)
          else
            # Cannot kill (7+ point cards) - keep all cards
            Map.put(acc, pos, [])
          end
        else
          acc
        end
      end)

    # Remove killed cards from hands and store in state
    new_players =
      players
      |> Enum.map(fn {pos, player} ->
        kills = Map.get(killed_cards, pos, [])
        new_hand = player.hand -- kills
        {pos, %{player | hand: new_hand}}
      end)
      |> Map.new()

    # Update state with killed cards and new hands
    state
    |> GameState.update(:killed_cards, killed_cards)
    |> GameState.update(:players, new_players)
    |> record_cards_killed_event(killed_cards)
    |> open_play()
  end

  # =============================================================================
  # Card Playing
  # =============================================================================

  @doc """
  Plays a card from a player's hand during the playing phase.

  This function validates that the card play is legal, removes the card from
  the player's hand, adds it to the current trick, and updates the turn order.
  If the trick is complete after this play, it automatically completes the trick.

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player playing the card
  - `card` - The card to play

  ## Returns
  - `{:ok, state}` - Updated state with card played
  - `{:error, reason}` - If the play is invalid

  ## State Changes
  - Removes card from player's hand
  - Adds play to current trick
  - Advances turn to next player (or trick leader if trick complete)
  - Records `{:card_played, position, card}` event
  - A player the turn reaches with no trumps goes cold and the turn moves on
  - If trick is complete, determines winner and awards points

  ## Validation
  - Game must be in `:playing` phase
  - Trump suit must be declared
  - Card must be in player's hand
  - Card must be a trump card (Finnish variant rule)
  - Must be player's turn

  ## Examples

      iex> state = %GameState{phase: :playing, trump_suit: :hearts, current_turn: :north}
      iex> player = %Player{hand: [{14, :hearts}, {10, :hearts}]}
      iex> state = put_in(state.players[:north], player)
      iex> {:ok, state} = Play.play_card(state, :north, {14, :hearts})
      iex> length(state.players[:north].hand)
      1
      iex> length(state.current_trick.plays)
      1
  """
  @spec play_card(game_state(), position(), card()) :: {:ok, game_state()} | {:error, error()}
  def play_card(%Types.GameState{} = state, position, card) do
    with :ok <- validate_playing_phase(state),
         :ok <- validate_trump_declared(state),
         {:ok, card} <- Errors.validate_card(card),
         :ok <- validate_play(state, position, card),
         {:ok, state} <- remove_card_from_hand(state, position, card),
         {:ok, state} <- add_card_to_trick(state, position, card),
         {:ok, state} <- record_card_played_event(state, position, card),
         {:ok, state} <- pass_turn(state, Types.next_position(position)) do
      {:ok, state}
    end
  end

  # =============================================================================
  # Play Validation
  # =============================================================================

  @doc """
  Validates that a card play is legal.

  In the Finnish variant, players must play trump cards. This function ensures:
  - The card is in the player's hand
  - The card is a trump card
  - The player has no trumps, they are eliminated and cannot play

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player
  - `card` - The card to validate

  ## Returns
  - `:ok` - If the play is valid
  - `{:error, reason}` - If the play is invalid

  ## Examples

      iex> state = %GameState{trump_suit: :hearts}
      iex> player = %Player{hand: [{14, :hearts}, {10, :clubs}]}
      iex> Play.validate_play(state, :north, {14, :hearts})
      :ok

      iex> Play.validate_play(state, :north, {10, :clubs})
      {:error, {:cannot_play_non_trump, {10, :clubs}, :hearts}}
  """
  @spec validate_play(game_state(), position(), card()) :: :ok | {:error, error()}
  def validate_play(%Types.GameState{} = state, position, card) do
    player = state.players[position]

    with :ok <- validate_card_in_hand(player, card),
         :ok <- validate_legal_card(state, position, card) do
      :ok
    end
  end

  @doc "Legal cards in hand order, using the game's rules and the trick's effective led suit."
  @spec legal_plays(game_state(), position()) :: [card()]
  def legal_plays(state, position) do
    led_suit =
      case state.current_trick do
        %Trick{plays: [{_leader, {_rank, suit} = card} | _]} ->
          if Card.is_trump?(card, state.trump_suit), do: state.trump_suit, else: suit

        _ ->
          nil
      end

    Pidro.Rules.for_variant(state.variant).legal_plays(
      state.players[position].hand,
      state.trump_suit,
      led_suit
    )
  end

  @doc """
  The next play of a settled hand: one player alone holds trumps and leads.

  Every card they hold is a trump that wins its own trick, so the order cannot
  change the score; this plays them highest first. Settled only between tricks,
  as a trick already led by a player who went cold still gives the holder a
  real choice. Louisiana players never go cold and still choose what to follow
  with, so its hands never settle.
  """
  @spec settled_play(game_state()) :: {position(), card()} | nil
  def settled_play(%Types.GameState{phase: :playing, trump_suit: trump} = state) do
    with false <- match?(%Trick{plays: [_ | _]}, state.current_trick),
         [{holder, %Player{hand: hand}}] <- Enum.reject(state.players, &elem(&1, 1).eliminated?),
         ^holder <- state.current_turn,
         [_ | _] = trumps <- Enum.filter(hand, &Card.is_trump?(&1, trump)) do
      {holder, Enum.max_by(trumps, & &1, &(Card.compare(&1, &2, trump) != :lt))}
    else
      _ -> nil
    end
  end

  def settled_play(_state), do: nil

  # Validates card is in player's hand
  @spec validate_card_in_hand(Player.t(), card()) :: :ok | {:error, error()}
  defp validate_card_in_hand(%Player{hand: hand}, card) do
    if card in hand do
      :ok
    else
      {:error, {:card_not_in_hand, card}}
    end
  end

  @spec validate_legal_card(game_state(), position(), card()) :: :ok | {:error, error()}
  defp validate_legal_card(state, position, card) do
    if card in legal_plays(state, position) do
      :ok
    else
      case state.variant do
        :finnish -> {:error, {:cannot_play_non_trump, card, state.trump_suit}}
        :louisiana -> {:error, {:invalid_action, {:play_card, card}, :playing}}
      end
    end
  end

  # =============================================================================
  # Trick Completion
  # =============================================================================

  @doc """
  Completes the current trick, determines the winner, and awards points.

  This function analyzes all plays in the current trick, determines which
  card (and therefore which player) won the trick, calculates the point value
  of the trick, and updates the game state accordingly.

  ## Parameters
  - `state` - Current game state with a complete trick

  ## Returns
  - `{:ok, state}` - Updated state with trick completed
  - `{:error, reason}` - If trick cannot be completed

  ## State Changes
  - Moves current_trick to tricks history
  - Sets current_trick to nil
  - Awards points to winning team
  - Increments tricks_won for winning player
  - Records `{:trick_won, position, points}` event
  - Sets current_turn to trick winner (for next trick)
  - Creates new trick if more cards remain to be played

  ## Trick Winner Determination
  - The highest trump card wins
  - Trump ranking: A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2
  - First card played wins ties (shouldn't happen with unique cards)

  ## Examples

      iex> trick = %Trick{
      ...>   plays: [{:north, {14, :hearts}}, {:east, {10, :hearts}}],
      ...>   leader: :north
      ...> }
      iex> state = %GameState{current_trick: trick, trump_suit: :hearts}
      iex> {:ok, state} = Play.complete_trick(state)
      iex> state.current_trick
      nil
      iex> length(state.tricks)
      1
  """
  @spec complete_trick(game_state()) :: {:ok, game_state()} | {:error, error()}
  def complete_trick(%Types.GameState{current_trick: nil} = _state) do
    {:error, :no_current_trick}
  end

  def complete_trick(%Types.GameState{current_trick: trick, trump_suit: trump_suit} = state) do
    with {:ok, winner, points} <- determine_trick_winner(trick, trump_suit, state.variant),
         {:ok, state} <- award_trick_points(state, winner, points),
         {:ok, state} <- record_trick_won_event(state, winner, points),
         {:ok, state} <- move_trick_to_history(state),
         {:ok, state} <- pass_turn(state, winner),
         {:ok, state} <- maybe_start_next_trick(state) do
      {:ok, state}
    end
  end

  @doc """
  Determines the winner of a completed trick and calculates points.

  Analyzes all plays in the trick to find the highest trump card.
  Calculates total point value from all cards in the trick.

  ## Parameters
  - `trick` - The completed trick
  - `trump_suit` - The declared trump suit

  ## Returns
  - `{:ok, winner_position, points}` - Winner and point value
  - `{:error, reason}` - If winner cannot be determined

  ## Examples

      iex> trick = %Trick{plays: [{:north, {14, :hearts}}, {:east, {10, :hearts}}]}
      iex> Play.determine_trick_winner(trick, :hearts)
      {:ok, :north, 2}
  """
  @spec determine_trick_winner(Trick.t(), suit()) ::
          {:ok, position(), non_neg_integer()} | {:error, error()}
  @spec determine_trick_winner(Trick.t(), suit(), atom()) ::
          {:ok, position(), non_neg_integer()} | {:error, error()}
  def determine_trick_winner(trick, trump_suit, variant \\ :finnish)

  def determine_trick_winner(%Trick{plays: []}, _trump_suit, _variant) do
    {:error, :trick_has_no_plays}
  end

  def determine_trick_winner(%Trick{plays: plays}, trump_suit, variant) do
    winner_position = Pidro.Rules.for_variant(variant).winner(plays, trump_suit)

    # Calculate total points in the trick
    points =
      plays
      |> Enum.map(fn {_pos, card} -> Card.point_value(card, trump_suit) end)
      |> Enum.sum()

    {:ok, winner_position, points}
  end

  # =============================================================================
  # Player Elimination
  # =============================================================================

  @doc """
  Marks a player as eliminated ("going cold") when they run out of trump cards.

  In Finnish Pidro, when a player has no more trump cards, they are eliminated
  from the rest of the hand. Their remaining non-trump cards are revealed to
  all players, and they cannot play in subsequent tricks.

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player to eliminate

  ## Returns
  - `{:ok, state}` - Updated state with player eliminated
  - `{:error, reason}` - If elimination fails

  ## State Changes
  - Sets player's `eliminated?` to `true`
  - Moves non-trump cards from hand to `revealed_cards`
  - Clears player's hand
  - Records `{:player_went_cold, position, revealed_cards}` event

  ## Examples

      iex> player = %Player{hand: [{10, :clubs}, {7, :spades}]}
      iex> state = %GameState{trump_suit: :hearts, players: %{north: player}}
      iex> {:ok, state} = Play.eliminate_player(state, :north)
      iex> state.players[:north].eliminated?
      true
      iex> state.players[:north].revealed_cards
      [{10, :clubs}, {7, :spades}]
  """
  @spec eliminate_player(game_state(), position()) :: {:ok, game_state()} | {:error, error()}
  def eliminate_player(%Types.GameState{} = state, position) do
    player = state.players[position]
    trump_suit = state.trump_suit

    # Get non-trump cards to reveal
    non_trump_cards = Trump.get_non_trump_cards(player.hand, trump_suit)

    # Update player state
    updated_player = %{
      player
      | eliminated?: true,
        revealed_cards: non_trump_cards,
        hand: []
    }

    # Update state
    updated_players = Map.put(state.players, position, updated_player)
    updated_state = GameState.update(state, :players, updated_players)

    # Record event
    event = {:player_went_cold, position, non_trump_cards}
    updated_events = state.events ++ [event]
    final_state = GameState.update(updated_state, :events, updated_events)

    {:ok, final_state}
  end

  @doc """
  Reveals a player's non-trump cards when they go cold.

  This is called as part of the elimination process. In Finnish Pidro,
  when a player runs out of trumps, their remaining non-trump "camouflage"
  cards are revealed to all other players.

  ## Parameters
  - `state` - Current game state
  - `position` - Position of the player

  ## Returns
  - `{:ok, revealed_cards}` - List of non-trump cards that were revealed

  ## Examples

      iex> player = %Player{hand: [{10, :clubs}, {7, :spades}]}
      iex> state = %GameState{trump_suit: :hearts, players: %{north: player}}
      iex> Play.reveal_non_trumps(state, :north)
      {:ok, [{10, :clubs}, {7, :spades}]}
  """
  @spec reveal_non_trumps(game_state(), position()) :: {:ok, [card()]}
  def reveal_non_trumps(%Types.GameState{} = state, position) do
    player = state.players[position]
    trump_suit = state.trump_suit

    non_trump_cards = Trump.get_non_trump_cards(player.hand, trump_suit)
    {:ok, non_trump_cards}
  end

  # =============================================================================
  # Turn Management
  # =============================================================================

  @doc """
  Handles trick leadership and turn rotation.

  After a trick is complete, the winner becomes the leader of the next trick.
  During a trick, turns rotate clockwise through non-eliminated players.

  ## Parameters
  - `state` - Current game state
  - `next_leader` - Position of the next trick leader

  ## Returns
  - `{:ok, state}` - Updated state with new leader

  ## Examples

      iex> state = %GameState{current_turn: :north}
      iex> {:ok, state} = Play.set_trick_leader(state, :east)
      iex> state.current_turn
      :east
  """
  @spec set_trick_leader(game_state(), position()) :: {:ok, game_state()}
  def set_trick_leader(%Types.GameState{} = state, leader) do
    updated_state = GameState.update(state, :current_turn, leader)
    {:ok, updated_state}
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  # Validates game is in playing phase
  @spec validate_playing_phase(game_state()) :: :ok | {:error, error()}
  defp validate_playing_phase(%Types.GameState{phase: :playing}), do: :ok

  defp validate_playing_phase(%Types.GameState{phase: actual_phase}) do
    {:error, {:invalid_phase, :playing, actual_phase}}
  end

  # Validates trump suit is declared
  @spec validate_trump_declared(game_state()) :: :ok | {:error, error()}
  defp validate_trump_declared(%Types.GameState{trump_suit: nil}) do
    {:error, {:trump_not_declared, "Trump suit must be declared before playing cards"}}
  end

  defp validate_trump_declared(%Types.GameState{trump_suit: _suit}), do: :ok

  # Removes card from player's hand
  @spec remove_card_from_hand(game_state(), position(), card()) ::
          {:ok, game_state()} | {:error, error()}
  defp remove_card_from_hand(state, position, card) do
    player = state.players[position]
    updated_hand = List.delete(player.hand, card)
    updated_player = %{player | hand: updated_hand}
    updated_players = Map.put(state.players, position, updated_player)
    updated_state = GameState.update(state, :players, updated_players)
    {:ok, updated_state}
  end

  # Adds card to current trick
  @spec add_card_to_trick(game_state(), position(), card()) :: {:ok, game_state()}
  defp add_card_to_trick(state, position, card) do
    trick = state.current_trick || create_new_trick(state)
    updated_plays = trick.plays ++ [{position, card}]
    updated_trick = %{trick | plays: updated_plays}
    updated_state = GameState.update(state, :current_trick, updated_trick)
    {:ok, updated_state}
  end

  # Creates a new trick
  @spec create_new_trick(game_state()) :: Trick.t()
  defp create_new_trick(state) do
    %Trick{
      number: state.trick_number + 1,
      leader: state.current_turn,
      plays: [],
      winner: nil,
      points: 0
    }
  end

  # Records card played event
  @spec record_card_played_event(game_state(), position(), card()) :: {:ok, game_state()}
  defp record_card_played_event(state, position, card) do
    event = {:card_played, position, card}
    updated_events = state.events ++ [event]
    updated_state = GameState.update(state, :events, updated_events)
    {:ok, updated_state}
  end

  # Play opens on the leader's turn, which may find them already cold. The
  # engine runs this after every play too, when the turn is already settled.
  defp open_play(%Types.GameState{phase: :playing, trump_suit: trump, current_turn: turn} = state)
       when not is_nil(trump) and not is_nil(turn) do
    {:ok, state} = pass_turn(state, turn)
    state
  end

  defp open_play(%Types.GameState{} = state), do: state

  # The turn reaches `position`. A player whose turn comes with no trump to
  # play goes cold there and then, and the turn moves on; once every player
  # still in has played, the trick is complete and its winner's turn comes.
  @spec pass_turn(game_state(), position()) :: {:ok, game_state()} | {:error, error()}
  defp pass_turn(state, position) do
    cond do
      Enum.all?(state.players, fn {_pos, player} -> player.eliminated? end) ->
        {:ok, GameState.update(state, :current_turn, nil)}

      trick_complete?(state) ->
        complete_trick(state)

      not match?(%Player{eliminated?: false}, state.players[position]) ->
        pass_turn(state, Types.next_position(position))

      goes_cold?(state, state.players[position]) ->
        {:ok, state} = eliminate_player(state, position)
        pass_turn(state, Types.next_position(position))

      true ->
        {:ok, GameState.update(state, :current_turn, position)}
    end
  end

  defp goes_cold?(state, %Player{hand: hand}) do
    Pidro.Rules.for_variant(state.variant).eliminate?(hand, state.trump_suit)
  end

  # Checks if current trick is complete (all active players have played)
  @spec trick_complete?(game_state()) :: boolean()
  defp trick_complete?(%Types.GameState{current_trick: nil}), do: false

  defp trick_complete?(state) do
    played_positions =
      state.current_trick.plays
      |> Enum.map(fn {pos, _} -> pos end)

    active_positions =
      state.players
      |> Enum.filter(fn {_pos, player} -> not player.eliminated? end)
      |> Enum.map(fn {pos, _} -> pos end)

    # Check if all active positions are in played positions
    Enum.all?(active_positions, fn pos -> pos in played_positions end)
  end

  # Awards trick points to winning team
  @spec award_trick_points(game_state(), position(), non_neg_integer()) :: {:ok, game_state()}
  defp award_trick_points(state, winner_position, points) do
    # Get winner's team
    winner_team = Types.position_to_team(winner_position)

    # Update hand_points
    current_points = state.hand_points[winner_team]
    updated_hand_points = Map.put(state.hand_points, winner_team, current_points + points)
    state = GameState.update(state, :hand_points, updated_hand_points)

    # Increment tricks_won for winning player
    winner = state.players[winner_position]
    updated_winner = %{winner | tricks_won: winner.tricks_won + 1}
    updated_players = Map.put(state.players, winner_position, updated_winner)
    state = GameState.update(state, :players, updated_players)

    {:ok, state}
  end

  # Records trick won event
  @spec record_trick_won_event(game_state(), position(), non_neg_integer()) :: {:ok, game_state()}
  defp record_trick_won_event(state, winner, points) do
    event = {:trick_won, winner, points}
    updated_events = state.events ++ [event]
    updated_state = GameState.update(state, :events, updated_events)
    {:ok, updated_state}
  end

  # Moves current trick to history
  @spec move_trick_to_history(game_state()) :: {:ok, game_state()}
  defp move_trick_to_history(state) do
    signals =
      Pidro.Finnish.Scorer.trick_signals(state.current_trick, state.trump_suit, state.variant)

    trick = %{
      state.current_trick
      | winner: signals.winning.position,
        points: signals.points,
        two_of_trump: signals.two_of_trump
    }

    updated_tricks = state.tricks ++ [trick]
    state = GameState.update(state, :tricks, updated_tricks)
    state = GameState.update(state, :current_trick, nil)
    state = GameState.update(state, :last_hand, nil)
    {:ok, state}
  end

  # Maybe starts next trick if there are cards remaining
  @spec maybe_start_next_trick(game_state()) :: {:ok, game_state()}
  defp maybe_start_next_trick(state) do
    # Check if any player has cards remaining
    any_cards_remain =
      state.players
      |> Enum.any?(fn {_pos, player} ->
        not player.eliminated? and length(player.hand) > 0
      end)

    if any_cards_remain do
      # Increment trick number for next trick
      updated_trick_number = state.trick_number + 1
      state = GameState.update(state, :trick_number, updated_trick_number)
      {:ok, state}
    else
      # No more cards, playing phase is complete
      {:ok, state}
    end
  end

  # Records cards killed event
  @spec record_cards_killed_event(game_state(), map()) :: game_state()
  defp record_cards_killed_event(state, killed_cards) do
    event = {:cards_killed, killed_cards}
    updated_events = state.events ++ [event]
    GameState.update(state, :events, updated_events)
  end
end
