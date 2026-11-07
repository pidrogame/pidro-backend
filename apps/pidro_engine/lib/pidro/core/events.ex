defmodule Pidro.Core.Events do
  @moduledoc """
  Event sourcing system for the Pidro game engine.

  This module provides structured event handling for reconstructing game state
  from a sequence of events. Every state-changing action in the game produces
  an event that can be replayed to reconstruct the exact game state.

  ## Event Types

  Events are categorized by game phase:

  ### Setup Phase
  - `:dealer_selected` - Initial dealer determined by deck cut
  - `:cards_dealt` - Initial 9-card deal to all players

  ### Bidding Phase
  - `:bid_made` - Player makes a bid (6-14)
  - `:player_passed` - Player passes on bidding
  - `:bidding_complete` - Bidding phase ends with winner

  ### Trump Declaration Phase
  - `:trump_declared` - Winning bidder declares trump suit
  - `:cards_discarded` - Player discards non-trump cards
  - `:cards_killed` - Cards eliminated from play (hidden info auditing)
  - `:second_deal_complete` - Final deal to 6 cards, dealer robs pack
  - `:dealer_robbed_pack` - Dealer takes pack and selects final hand

  ### Playing Phase
  - `:card_played` - Player plays a trump card
  - `:trick_won` - Trick complete, winner determined
  - `:player_went_cold` - Player eliminated (out of trumps)
  - `:hand_settled` - The lone trump holder lays their trumps down

  ### Scoring Phase
  - `:hand_scored` - Hand complete, scores calculated
  - `:game_won` - Game complete, winning team determined

  ## Event Structure

  Each event is represented as an `Event` struct containing:
  - `type` - The event type atom
  - `data` - Event-specific data (varies by type)
  - `timestamp` - When the event occurred
  - `hand_number` - Which hand this event belongs to

  ## Event Sourcing

  Game state can be reconstructed by replaying events:

      iex> events = [
      ...>   %Event{type: :dealer_selected, data: {:north, {14, :hearts}}, hand_number: 1},
      ...>   %Event{type: :cards_dealt, data: %{north: [...], ...}, hand_number: 1}
      ...> ]
      iex> final_state = Enum.reduce(events, GameState.new(seed: 7), &Events.apply_event/2)

  ## Immutability

  All event applications are immutable - they return a new GameState without
  modifying the original. This enables:
  - Safe concurrent reads
  - Time-travel debugging
  - Undo/redo functionality
  - State snapshots at any point
  """

  use TypedStruct

  alias Pidro.Core.Types
  alias Pidro.Core.Types.{GameState, Bid, Trick}

  # =============================================================================
  # Event Struct Definition
  # =============================================================================

  typedstruct module: Event do
    @moduledoc """
    Structured event for event sourcing.

    Wraps the raw event tuples defined in Types with additional metadata
    for tracking and replay purposes.

    ## Fields

    - `type` - Event type atom (e.g., `:dealer_selected`, `:bid_made`)
    - `data` - Event-specific data matching the event tuple structure
    - `timestamp` - DateTime when event occurred
    - `hand_number` - Hand number when event occurred (1-based)

    ## Examples

        iex> event = %Event{
        ...>   type: :dealer_selected,
        ...>   data: {:north, {14, :hearts}},
        ...>   timestamp: DateTime.utc_now(),
        ...>   hand_number: 1
        ...> }
    """
    field(:type, atom(), enforce: true)
    field(:data, any(), enforce: true)
    field(:timestamp, DateTime.t(), enforce: true)
    field(:hand_number, non_neg_integer(), enforce: true)
  end

  # =============================================================================
  # Event Application
  # =============================================================================

  @doc """
  Applies a single event to a GameState and returns the updated state.

  This function pattern matches on event types and applies the appropriate
  state transformations. Events are expected to be in the tuple format
  defined in `Pidro.Core.Types.event()`.

  ## Parameters

  - `state` - Current GameState
  - `event` - Event tuple to apply (from Types.event())

  ## Returns

  Updated `GameState.t()` with the event applied.

  ## Event Types Handled

  ### Dealer Selection
  - `{:dealer_selected, position, card}` - Sets current_dealer

  ### Dealing
  - `{:cards_dealt, hands}` - Distributes cards to players

  ### Bidding
  - `{:bid_made, position, amount}` - Records bid, updates highest_bid
  - `{:player_passed, position}` - Records pass
  - `{:bidding_complete, position, amount}` - Sets bidding winner and team

  ### Trump Declaration
  - `{:trump_declared, suit}` - Sets trump suit

  ### Discarding
  - `{:cards_discarded, position, cards}` - Removes cards from player's hand
  - `{:cards_killed, killed_map}` - Records cards eliminated from play
  - `{:second_deal_complete, %{dealt: hands_map, requested: req_map}}` - Updates hands with final cards and records card requests
  - `{:dealer_robbed_pack, dealer, took_count, kept_count}` - Dealer auditing event (counts instead of card lists)

  ### Playing
  - `{:card_played, position, card}` - Adds card to current trick
  - `{:trick_won, position, points}` - Completes trick, awards points
  - `{:player_went_cold, position, revealed}` - Eliminates player
  - `{:hand_settled, position, cards}` - Announces the plays that follow

  ### Scoring
  - `{:hand_scored, team, points}` - Updates cumulative scores
  - `{:game_won, team, score}` - Sets winner, marks game complete

  ## Examples

      iex> state = GameState.new(seed: 7)
      iex> event = {:dealer_selected, :north, {14, :hearts}}
      iex> state = Events.apply_event(state, event)
      iex> state.current_dealer
      :north

      iex> state = GameState.new(seed: 7)
      iex> event = {:trump_declared, :hearts}
      iex> state = Events.apply_event(state, event)
      iex> state.trump_suit
      :hearts
  """
  @spec apply_event(GameState.t(), Types.event()) :: GameState.t()

  # Dealer Selection Phase
  def apply_event(state, {:dealer_selected, position, _card}) do
    %{state | current_dealer: position}
  end

  # Dealing Phase
  def apply_event(state, {:cards_dealt, hands}) when is_map(hands) do
    updated_players =
      Enum.reduce(hands, state.players, fn {position, cards}, players ->
        player = Map.get(players, position)
        updated_player = %{player | hand: cards}
        Map.put(players, position, updated_player)
      end)

    %{state | players: updated_players}
  end

  # Bidding Phase
  def apply_event(state, {:bid_made, position, amount}) do
    bid = %Bid{
      position: position,
      amount: amount,
      timestamp: length(state.bids)
    }

    %{state | bids: state.bids ++ [bid], highest_bid: {position, amount}}
  end

  def apply_event(state, {:player_passed, position}) do
    bid = %Bid{
      position: position,
      amount: :pass,
      timestamp: length(state.bids)
    }

    %{state | bids: state.bids ++ [bid]}
  end

  def apply_event(state, {:bidding_complete, position, amount}) do
    team = Types.position_to_team(position)

    %{state | highest_bid: {position, amount}, bidding_team: team}
  end

  # Trump Declaration Phase
  def apply_event(state, {:trump_declared, suit}) do
    %{state | trump_suit: suit}
  end

  # Discarding Phase
  def apply_event(state, {:cards_discarded, position, cards}) do
    player = Map.get(state.players, position)
    remaining_hand = player.hand -- cards

    updated_player = %{player | hand: remaining_hand}
    updated_players = Map.put(state.players, position, updated_player)

    %{state | players: updated_players, discarded_cards: state.discarded_cards ++ cards}
  end

  def apply_event(state, {:cards_killed, killed_map}) do
    updated_killed_cards = Map.merge(state.killed_cards, killed_map)
    %{state | killed_cards: updated_killed_cards}
  end

  def apply_event(state, {:second_deal_complete, %{dealt: hands_map, requested: req_map}}) do
    updated_players =
      Enum.reduce(hands_map, state.players, fn {position, cards}, players ->
        player = Map.get(players, position)
        updated_player = %{player | hand: player.hand ++ cards}
        Map.put(players, position, updated_player)
      end)

    %{state | players: updated_players, cards_requested: req_map}
  end

  # Legacy handler for backward compatibility with simpler format
  def apply_event(state, {:second_deal_complete, hands}) when is_map(hands) do
    updated_players =
      Enum.reduce(hands, state.players, fn {position, cards}, players ->
        player = Map.get(players, position)
        updated_player = %{player | hand: player.hand ++ cards}
        Map.put(players, position, updated_player)
      end)

    %{state | players: updated_players}
  end

  def apply_event(state, {:dealer_robbed_pack, _dealer, _took_count, _kept_count}) do
    # Note: We don't reconstruct exact cards from counts (hidden info)
    # This event is just for auditing/logging
    state
  end

  # Playing Phase
  def apply_event(state, {:card_played, position, card}) do
    # Remove card from player's hand
    player = Map.get(state.players, position)
    updated_hand = List.delete(player.hand, card)
    updated_player = %{player | hand: updated_hand}
    updated_players = Map.put(state.players, position, updated_player)

    # Add play to current trick
    current_trick =
      state.current_trick ||
        %Trick{
          number: state.trick_number + 1,
          leader: position,
          plays: []
        }

    updated_trick = %{current_trick | plays: current_trick.plays ++ [{position, card}]}

    %{state | players: updated_players, current_trick: updated_trick}
  end

  def apply_event(state, {:trick_won, position, points}) do
    team = Types.position_to_team(position)

    # Update player tricks won
    player = Map.get(state.players, position)
    updated_player = %{player | tricks_won: player.tricks_won + 1}
    updated_players = Map.put(state.players, position, updated_player)

    # Update trick with winner and points
    updated_trick = %{state.current_trick | winner: position, points: points}

    # Update hand points for the team
    updated_hand_points = Map.update!(state.hand_points, team, &(&1 + points))

    %{
      state
      | players: updated_players,
        tricks: state.tricks ++ [updated_trick],
        current_trick: nil,
        trick_number: state.trick_number + 1,
        hand_points: updated_hand_points,
        current_turn: position
    }
  end

  def apply_event(state, {:player_went_cold, position, revealed_cards}) do
    player = Map.get(state.players, position)

    updated_player = %{player | eliminated?: true, revealed_cards: revealed_cards}

    updated_players = Map.put(state.players, position, updated_player)

    %{state | players: updated_players}
  end

  # The holder's card plays follow as their own events.
  def apply_event(state, {:hand_settled, _position, _cards}), do: state

  # Scoring Phase
  def apply_event(state, {:hand_scored, team, points}) do
    updated_cumulative = Map.update!(state.cumulative_scores, team, &(&1 + points))

    %{state | cumulative_scores: updated_cumulative}
  end

  def apply_event(state, {:game_won, team, _final_score}) do
    %{state | winner: team, phase: :complete}
  end

  # =============================================================================
  # Event Creation Helpers
  # =============================================================================

  @doc """
  Creates a structured Event from a raw event tuple.

  Wraps the event tuple in an Event struct with timestamp and hand number
  for better tracking and replay capabilities.

  ## Parameters

  - `event_tuple` - Raw event tuple (from Types.event())
  - `hand_number` - Current hand number

  ## Returns

  `Event.t()` struct with metadata.

  ## Examples

      iex> event = Events.create_event({:dealer_selected, :north, {14, :hearts}}, 1)
      iex> event.type
      :dealer_selected
      iex> event.hand_number
      1
  """
  @spec create_event(Types.event(), non_neg_integer()) :: Event.t()
  def create_event(event_tuple, hand_number) do
    type = elem(event_tuple, 0)

    %Event{
      type: type,
      data: event_tuple,
      timestamp: DateTime.utc_now(),
      hand_number: hand_number
    }
  end

  @doc """
  Replays a sequence of events to reconstruct game state.

  Takes an initial state and a list of events, applying each event in order
  to produce the final state. This is the core of the event sourcing system.

  ## Parameters

  - `initial_state` - Starting GameState (typically `GameState.new(seed: 7)`)
  - `events` - List of event tuples to apply in order

  ## Returns

  Final `GameState.t()` after all events applied.

  ## Examples

      iex> events = [
      ...>   {:dealer_selected, :north, {14, :hearts}},
      ...>   {:trump_declared, :hearts}
      ...> ]
      iex> state = Events.replay_events(GameState.new(seed: 7), events)
      iex> state.current_dealer
      :north
      iex> state.trump_suit
      :hearts
  """
  @spec replay_events(GameState.t(), [Types.event()]) :: GameState.t()
  def replay_events(initial_state, events) do
    Enum.reduce(events, initial_state, fn event, state ->
      apply_event(state, event)
    end)
  end
end
