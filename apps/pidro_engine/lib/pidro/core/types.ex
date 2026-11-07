defmodule Pidro.Core.Types do
  @moduledoc """
  Core type definitions for the Pidro game engine.

  This module defines all fundamental types used throughout the game engine,
  including cards, positions, teams, game phases, actions, and events.

  ## Design Philosophy

  - All types are immutable
  - Uses Elixir's built-in types where possible
  - Leverages TypedStruct for cleaner struct definitions
  - Full Dialyzer support with @spec annotations

  ## Finnish Variant Specifics

  The Finnish variant of Pidro has unique characteristics:
  - Only trump cards are played (non-trumps are "camouflage")
  - 14 trump cards per suit (includes the "wrong 5" from same-color suit)
  - Players eliminated when out of trumps ("going cold")
  - Special 2 of trump rule: player keeps 1 point
  """

  use TypedStruct

  # =============================================================================
  # Basic Card Types
  # =============================================================================

  @typedoc """
  Card suit in standard 52-card deck.

  Hearts and Diamonds are red suits (same color).
  Clubs and Spades are black suits (same color).
  """
  @type suit :: :hearts | :diamonds | :clubs | :spades

  @typedoc """
  Card rank using numeric representation.

  - 2-10: Face value
  - 11: Jack
  - 12: Queen
  - 13: King
  - 14: Ace (high)
  """
  @type rank :: 2..14

  @typedoc """
  A playing card represented as a tuple of rank and suit.

  ## Examples

      {14, :hearts}  # Ace of Hearts
      {11, :spades}  # Jack of Spades
      {5, :diamonds} # 5 of Diamonds (potentially "wrong 5")
  """
  @type card :: {rank(), suit()}

  @typedoc """
  The engine's explicit chance stream — an exported `:rand` state.

  Carried in `GameState.chance` and advanced by `Pidro.Core.Chance`, which is
  the only module in the game domain permitted to touch `:rand`. The value is
  plain data (`{algorithm, algorithm_state}`), so it round-trips through
  `:erlang.term_to_binary/1` and can be continued in another process.
  """
  @type chance :: :rand.export_state()

  # =============================================================================
  # Player and Team Types
  # =============================================================================

  @typedoc """
  Player position at the table.

  Positions are arranged clockwise: North -> East -> South -> West
  Partners sit opposite each other: North/South and East/West
  """
  @type position :: :north | :east | :south | :west

  @typedoc """
  Team designation based on partnership.

  - `:north_south` - North and South players
  - `:east_west` - East and West players
  """
  @type team :: :north_south | :east_west

  # =============================================================================
  # Game Phase Types
  # =============================================================================

  @typedoc """
  Current phase of the game.

  ## Phase Flow

  1. `:dealer_selection` - Cut for dealer (first hand only)
  2. `:dealing` - Initial deal of 9 cards each
  3. `:bidding` - Bidding round (6-14 points)
  4. `:declaring` - Winner declares trump suit
  5. `:discarding` - Players discard non-trumps
  6. `:second_deal` - Deal to 6 cards each, dealer robs pack
  7. `:playing` - Trick-taking phase
  8. `:scoring` - Calculate and apply scores
  9. `:hand_complete` - Prepare the next hand when the game has no winner
  10. `:complete` - Game over (one team reached 62)
  """
  @type phase ::
          :dealer_selection
          | :dealing
          | :bidding
          | :declaring
          | :discarding
          | :second_deal
          | :playing
          | :scoring
          | :hand_complete
          | :complete

  # =============================================================================
  # Action Types
  # =============================================================================

  @typedoc """
  Valid bid amount (6 to 14 points inclusive).
  """
  @type bid_amount :: 6..14

  @typedoc """
  All possible player actions in the game.

  ## Dealer Selection
  - `{:cut_deck, position}` - Cut deck to determine dealer

  ## Bidding Phase
  - `{:bid, amount}` - Make a bid (6-14)
  - `:pass` - Pass on bidding

  ## Declaring Phase
  - `{:declare_trump, suit}` - Declare trump suit

  ## Discarding Phase
  - `{:discard, cards}` - Discard non-trump cards
  - `{:select_hand, cards}` - Dealer selects final 6 cards after robbing

  ## Playing Phase
  - `{:play_card, card}` - Play a trump card

  ## Meta Actions
  - `:resign` - Forfeit the game
  - `:claim_remaining` - Claim all remaining tricks
  """
  @type action ::
          {:cut_deck, position()}
          | {:bid, bid_amount()}
          | :pass
          | {:declare_trump, suit()}
          | {:discard, [card()]}
          | {:select_hand, [card()]}
          | {:play_card, card()}
          | :resign
          | :claim_remaining

  # =============================================================================
  # Event Types (Event Sourcing)
  # =============================================================================

  @typedoc """
  Game events for event sourcing and replay.

  Every action that modifies game state produces an event.
  Events are immutable and can be replayed to reconstruct game state.

  ## Event Categories

  - Setup: `dealer_selected`, `cards_dealt`
  - Bidding: `bid_made`, `player_passed`, `bidding_complete`
  - Trump: `trump_declared`, `cards_discarded`, `second_deal_complete`
  - Play: `card_played`, `trick_won`, `player_went_cold`, `hand_settled`
  - Scoring: `hand_scored`, `game_won`
  """
  @type event ::
          {:dealer_selected, position(), card()}
          | {:cards_dealt, %{position() => [card()]}}
          | {:bid_made, position(), bid_amount()}
          | {:player_passed, position()}
          | {:bidding_complete, position(), bid_amount()}
          | {:trump_declared, suit()}
          | {:cards_discarded, position(), [card()]}
          | {:second_deal_complete, %{position() => non_neg_integer()}}
          | {:dealer_robbed_pack, position(), non_neg_integer(), non_neg_integer()}
          | {:cards_killed, %{position() => [card()]}}
          | {:card_played, position(), card()}
          | {:trick_won, position(), points :: non_neg_integer()}
          | {:player_went_cold, position(), revealed_cards :: [card()]}
          | {:hand_settled, position(), laid :: [card()]}
          | {:hand_scored, team(), points :: integer()}
          | {:game_won, team(), score :: non_neg_integer()}

  # =============================================================================
  # Struct Types
  # =============================================================================

  typedstruct module: Bid do
    @moduledoc """
    Represents a bid made by a player.

    The amount can be:
    - A numeric bid (6-14)
    - `:pass` to indicate the player passed
    """
    field(:position, Pidro.Core.Types.position(), enforce: true)
    field(:amount, Pidro.Core.Types.bid_amount() | :pass, enforce: true)
    # Zero-based logical sequence. The legacy field name is retained for
    # serialized-state compatibility.
    field(:timestamp, integer(), default: 0)
  end

  typedstruct module: Trick do
    @moduledoc """
    Represents a single trick during play.

    A trick consists of up to 4 card plays (one per active player).
    The highest trump card wins, with special handling for the 2 of trump.
    """
    field(:number, pos_integer(), enforce: true)
    field(:leader, Pidro.Core.Types.position(), enforce: true)
    field(:plays, [{Pidro.Core.Types.position(), Pidro.Core.Types.card()}], default: [])
    field(:winner, Pidro.Core.Types.position() | nil, default: nil)
    field(:points, non_neg_integer(), default: 0)

    field(
      :two_of_trump,
      %{position: Pidro.Core.Types.position(), points: non_neg_integer()} | nil,
      default: nil
    )
  end

  typedstruct module: Player do
    @moduledoc """
    Represents a player's state during the game.

    ## Finnish Variant Notes
    - `eliminated?` indicates player has gone "cold" (out of trumps)
    - `revealed_cards` shows non-trump cards when going cold
    """
    field(:position, Pidro.Core.Types.position(), enforce: true)
    field(:team, Pidro.Core.Types.team(), enforce: true)
    field(:hand, [Pidro.Core.Types.card()], default: [])
    field(:eliminated?, boolean(), default: false)
    field(:revealed_cards, [Pidro.Core.Types.card()], default: [])
    field(:tricks_won, non_neg_integer(), default: 0)
  end

  typedstruct module: GameState do
    @moduledoc """
    Complete game state for a Pidro game.

    This struct contains all information needed to represent the current
    state of a game, including player hands, scores, history, and phase.

    ## Immutability

    All updates to GameState produce a new struct; the original is never modified.
    This enables:
    - Safe concurrent reads
    - Easy undo/replay functionality
    - Event sourcing
    - Time-travel debugging

    ## Event Sourcing

    The `events` field maintains a complete history of all state changes,
    allowing the game to be replayed from the beginning.
    """

    # Core game state
    field(:phase, Pidro.Core.Types.phase(), default: :dealer_selection)
    field(:hand_number, non_neg_integer(), default: 1)
    field(:variant, atom(), default: :finnish)

    # Players
    field(:players, %{Pidro.Core.Types.position() => Pidro.Core.Types.Player.t()}, enforce: true)
    field(:current_dealer, Pidro.Core.Types.position() | nil, default: nil)
    field(:current_turn, Pidro.Core.Types.position() | nil, default: nil)

    # Dealer selection ceremony (first hand only)
    field(:dealer_selection_cuts, %{Pidro.Core.Types.position() => Pidro.Core.Types.card()} | nil,
      default: nil
    )

    # Deck
    field(:deck, [Pidro.Core.Types.card()], default: [])
    field(:discarded_cards, [Pidro.Core.Types.card()], default: [])

    # Bidding
    field(:bids, [Pidro.Core.Types.Bid.t()], default: [])

    field(:highest_bid, {Pidro.Core.Types.position(), Pidro.Core.Types.bid_amount()} | nil,
      default: nil
    )

    field(:bidding_team, Pidro.Core.Types.team() | nil, default: nil)

    # Trump
    field(:trump_suit, Pidro.Core.Types.suit() | nil, default: nil)

    # Re-deal tracking fields
    field(:cards_requested, %{Pidro.Core.Types.position() => non_neg_integer()}, default: %{})
    field(:dealer_pool_size, non_neg_integer() | nil, default: nil)

    field(:killed_cards, %{Pidro.Core.Types.position() => [Pidro.Core.Types.card()]},
      default: %{}
    )

    # Play
    field(:tricks, [Pidro.Core.Types.Trick.t()], default: [])
    field(:current_trick, Pidro.Core.Types.Trick.t() | nil, default: nil)
    field(:trick_number, non_neg_integer(), default: 0)

    # Scoring
    field(:hand_points, %{Pidro.Core.Types.team() => non_neg_integer()},
      default: %{north_south: 0, east_west: 0}
    )

    field(:cumulative_scores, %{Pidro.Core.Types.team() => integer()},
      default: %{north_south: 0, east_west: 0}
    )

    field(:winner, Pidro.Core.Types.team() | nil, default: nil)
    field(:last_hand, map() | nil, default: nil)
    # Every scored hand of this game, oldest first, without per-trick detail.
    field(:hand_history, [map()], default: [])

    # History (for replay/undo)
    field(:events, [Pidro.Core.Types.event()], default: [])

    # Configuration
    field(:config, map(),
      default: %{
        min_bid: 6,
        max_bid: 14,
        winning_score: 62,
        initial_deal_count: 9,
        final_hand_size: 6,
        allow_negative_scores: true,
        auto_dealer_rob: true
      }
    )

    # Explicit chance stream — every random draw the engine makes is derived
    # from this value, never from the calling process's `:rand` dictionary.
    # Built by `Pidro.Core.GameState.new/1` from a seed and advanced in place by
    # `Pidro.Core.Chance`. `nil` means the state did not come from `new/1` —
    # either a hand-assembled test fixture, or a decoder whose format does not
    # carry chance (`Pidro.Core.Binary.from_binary/1`). Such a state cannot
    # cross a transition that draws, and will fail loudly if it tries.
    field(:chance, Pidro.Core.Types.chance() | nil, default: nil)

    # Performance cache (optional, not serialized)
    field(:cache, map(), default: %{})
  end

  # =============================================================================
  # Type Guards and Utilities
  # =============================================================================

  @doc """
  Returns all valid suits.
  """
  @spec all_suits() :: [suit()]
  def all_suits, do: [:hearts, :diamonds, :clubs, :spades]

  @doc """
  Returns all valid positions.
  """
  @spec all_positions() :: [position()]
  def all_positions, do: [:north, :east, :south, :west]

  @doc """
  Returns all valid phases in order.
  """
  @spec all_phases() :: [phase()]
  def all_phases do
    [
      :dealer_selection,
      :dealing,
      :bidding,
      :declaring,
      :discarding,
      :second_deal,
      :playing,
      :scoring,
      :hand_complete,
      :complete
    ]
  end

  @doc """
  Returns the team for a given position.
  """
  @spec position_to_team(position()) :: team()
  def position_to_team(:north), do: :north_south
  def position_to_team(:south), do: :north_south
  def position_to_team(:east), do: :east_west
  def position_to_team(:west), do: :east_west

  @doc """
  Returns the positions for a given team.
  """
  @spec team_to_positions(team()) :: [position()]
  def team_to_positions(:north_south), do: [:north, :south]
  def team_to_positions(:east_west), do: [:east, :west]

  @doc """
  Returns the partner position for a given position.
  """
  @spec partner_position(position()) :: position()
  def partner_position(:north), do: :south
  def partner_position(:south), do: :north
  def partner_position(:east), do: :west
  def partner_position(:west), do: :east

  @doc """
  Returns the next position clockwise.
  """
  @spec next_position(position()) :: position()
  def next_position(:north), do: :east
  def next_position(:east), do: :south
  def next_position(:south), do: :west
  def next_position(:west), do: :north

  @doc """
  Returns the opposing team.
  """
  @spec opposing_team(team()) :: team()
  def opposing_team(:north_south), do: :east_west
  def opposing_team(:east_west), do: :north_south

  @doc """
  Returns the same-color suit for a given suit.

  Used for determining the "wrong 5" in Finnish Pidro:
  - Hearts <-> Diamonds (red suits)
  - Clubs <-> Spades (black suits)
  """
  @spec same_color_suit(suit()) :: suit()
  def same_color_suit(:hearts), do: :diamonds
  def same_color_suit(:diamonds), do: :hearts
  def same_color_suit(:clubs), do: :spades
  def same_color_suit(:spades), do: :clubs

  @doc """
  Converts a rank number to its name.
  """
  @spec rank_to_name(rank()) :: String.t()
  def rank_to_name(14), do: "Ace"
  def rank_to_name(13), do: "King"
  def rank_to_name(12), do: "Queen"
  def rank_to_name(11), do: "Jack"
  def rank_to_name(n) when n >= 2 and n <= 10, do: "#{n}"

  @doc """
  Converts a suit atom to its name.
  """
  @spec suit_to_name(suit()) :: String.t()
  def suit_to_name(:hearts), do: "Hearts"
  def suit_to_name(:diamonds), do: "Diamonds"
  def suit_to_name(:clubs), do: "Clubs"
  def suit_to_name(:spades), do: "Spades"

  @doc """
  Converts a card to a human-readable string.
  """
  @spec card_to_string(card()) :: String.t()
  def card_to_string({rank, suit}) do
    "#{rank_to_name(rank)} of #{suit_to_name(suit)}"
  end

  @doc """
  Converts a position to a capitalized string.
  """
  @spec position_to_string(position()) :: String.t()
  def position_to_string(:north), do: "North"
  def position_to_string(:east), do: "East"
  def position_to_string(:south), do: "South"
  def position_to_string(:west), do: "West"

  @doc """
  Converts a team to a human-readable string.
  """
  @spec team_to_string(team()) :: String.t()
  def team_to_string(:north_south), do: "North/South"
  def team_to_string(:east_west), do: "East/West"
end
