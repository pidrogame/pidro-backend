defmodule Pidro.Finnish.Scorer do
  @moduledoc """
  Scoring logic for Finnish Pidro.

  This module handles all scoring operations including:
  - Scoring individual tricks with the special 2 of trump rule
  - Aggregating team scores from completed tricks
  - Applying bid results (success/failure) to cumulative scores
  - Determining game completion and winners

  ## Finnish Pidro Scoring Rules

  ### Point Distribution
  - Total available points per hand: 14
  - Points are awarded based on cards captured in tricks
  - The special 2 of trump rule affects point distribution

  ### The 2 of Trump Rule
  The 2 of trump has unique scoring behavior:
  - The player who plays the 2 of trump ALWAYS keeps 1 point
  - This point does NOT go to the trick winner
  - The trick winner receives all other points in the trick

  ### Bid Results
  After all tricks are played, scores are applied based on the bidding team's performance:

  **Bidding Team Made Bid:**
  - If points taken >= bid amount: score the points taken

  **Bidding Team Failed Bid:**
  - If points taken < bid amount: lose the bid amount (can go negative)

  **Defending Team:**
  - Always keep the points they took, regardless of bid outcome

  ### Game Completion
  - Game ends when any team reaches 62 points
  - If both teams reach 62 on the same hand, the bidding team wins
  - Scores can go negative if bidding team fails their bid

  ## Examples

      # Score a trick with special 2 rule
      iex> trick = %Pidro.Core.Types.Trick{
      ...>   number: 1,
      ...>   leader: :north,
      ...>   plays: [
      ...>     {:north, {14, :hearts}},  # Ace: 1 point
      ...>     {:east, {2, :hearts}},    # 2: 1 point (kept by player)
      ...>     {:south, {10, :hearts}},  # Ten: 1 point
      ...>     {:west, {7, :hearts}}     # Seven: 0 points
      ...>   ]
      ...> }
      iex> Pidro.Finnish.Scorer.score_trick(trick, :hearts)
      %{
        winner: :north,
        winner_points: 2,  # Ace + Ten (2 is kept by East)
        two_of_trump_player: :east,
        two_of_trump_points: 1
      }

      # Aggregate team scores
      iex> tricks = [
      ...>   %{winner: :north, winner_points: 5, two_of_trump_player: nil, two_of_trump_points: 0},
      ...>   %{winner: :east, winner_points: 6, two_of_trump_player: :south, two_of_trump_points: 1}
      ...> ]
      iex> Pidro.Finnish.Scorer.aggregate_team_scores(tricks)
      %{north_south: 6, east_west: 6}  # North (5) + South (1) vs East (6)

      # Apply bid result - bidding team made bid
      # (See test suite for detailed examples)
  """

  alias Pidro.Core.{Types, Card, GameState}

  @type position :: Types.position()
  @type suit :: Types.suit()
  @type team :: Types.team()
  @type card :: Types.card()

  @typedoc """
  Result of scoring a single trick.

  Fields:
  - `winner` - Position of the player who won the trick
  - `winner_points` - Points awarded to the trick winner
  - `two_of_trump_player` - Position of player who played 2 of trump (nil if not played)
  - `two_of_trump_points` - Points kept by 2 of trump player (1 or 0)
  """
  @type trick_score :: %{
          winner: position(),
          winner_points: non_neg_integer(),
          two_of_trump_player: position() | nil,
          two_of_trump_points: 0 | 1
        }

  @typedoc "A card that scored, with the seat and team that took its points."
  @type point_card :: %{card: card(), points: pos_integer(), position: position(), team: team()}

  # =============================================================================
  # Public API
  # =============================================================================

  @doc """
  Scores a single trick, handling the special 2 of trump rule.

  The 2 of trump is unique in Finnish Pidro:
  - The player who plays it always keeps 1 point
  - That point does NOT go to the trick winner
  - The trick winner gets all other points

  ## Parameters
  - `trick` - A completed `Trick.t()` struct with all plays
  - `trump_suit` - The declared trump suit for this hand

  ## Returns
  A map containing:
  - `:winner` - Position of the player who won the trick
  - `:winner_points` - Points awarded to trick winner (excluding 2 of trump)
  - `:two_of_trump_player` - Position of player who played 2 of trump (or `nil`)
  - `:two_of_trump_points` - Points kept by 2 player (1 if played, 0 otherwise)

  ## Examples

      iex> alias Pidro.Core.Types.Trick
      iex> trick = %Trick{
      ...>   number: 1,
      ...>   leader: :north,
      ...>   plays: [
      ...>     {:north, {14, :hearts}},  # Ace
      ...>     {:east, {11, :hearts}},   # Jack
      ...>     {:south, {10, :hearts}},  # Ten
      ...>     {:west, {7, :hearts}}     # Seven
      ...>   ]
      ...> }
      iex> Pidro.Finnish.Scorer.score_trick(trick, :hearts)
      %{
        winner: :north,
        winner_points: 3,
        two_of_trump_player: nil,
        two_of_trump_points: 0
      }

      iex> alias Pidro.Core.Types.Trick
      iex> trick = %Trick{
      ...>   number: 1,
      ...>   leader: :north,
      ...>   plays: [
      ...>     {:north, {5, :hearts}},    # Right 5: 5 points
      ...>     {:east, {2, :hearts}},     # 2 of trump: 1 point (kept by player)
      ...>     {:south, {10, :hearts}},   # Ten: 1 point (wins!)
      ...>     {:west, {4, :hearts}}      # Four: 0 points
      ...>   ]
      ...> }
      iex> Pidro.Finnish.Scorer.score_trick(trick, :hearts)
      %{
        winner: :south,
        winner_points: 6,  # Right 5 (5) + Ten (1)
        two_of_trump_player: :east,
        two_of_trump_points: 1
      }

      iex> alias Pidro.Core.Types.Trick
      iex> trick = %Trick{
      ...>   number: 1,
      ...>   leader: :north,
      ...>   plays: [
      ...>     {:north, {2, :hearts}},  # 2 of trump: 1 point (kept by player)
      ...>     {:east, {3, :hearts}}    # Three (wins - higher rank)
      ...>   ]
      ...> }
      iex> Pidro.Finnish.Scorer.score_trick(trick, :hearts)
      %{
        winner: :east,
        winner_points: 0,  # 2 player keeps their point
        two_of_trump_player: :north,
        two_of_trump_points: 1
      }
  """
  @spec score_trick(Types.Trick.t(), suit()) :: trick_score()
  @spec score_trick(Types.Trick.t(), suit(), atom()) :: trick_score()
  def score_trick(%Types.Trick{plays: plays, leader: leader}, trump_suit, variant \\ :finnish)
      when plays != [] do
    # Convert to Pidro.Core.Trick struct to use existing winner logic
    core_trick = %Pidro.Core.Trick{leader: leader, plays: plays}

    # Find the winner using existing Trick logic
    {:ok, winner} = Pidro.Core.Trick.winner(core_trick, trump_suit, variant)

    # Find if 2 of trump was played and by whom
    two_of_trump_info = find_two_of_trump(plays, trump_suit)

    # Calculate total points in trick
    total_points =
      plays
      |> Enum.map(fn {_pos, card} -> Card.point_value(card, trump_suit) end)
      |> Enum.sum()

    # Subtract the 2 of trump point if it was played
    winner_points =
      case two_of_trump_info do
        {_player, 1} -> max(total_points - 1, 0)
        _ -> total_points
      end

    case two_of_trump_info do
      {player, points} ->
        %{
          winner: winner,
          winner_points: winner_points,
          two_of_trump_player: player,
          two_of_trump_points: points
        }

      nil ->
        %{
          winner: winner,
          winner_points: winner_points,
          two_of_trump_player: nil,
          two_of_trump_points: 0
        }
    end
  end

  @doc """
  Returns the winning play and point split for a partial or completed trick.

  Both variants use the same point split, with their own winner rules. An empty
  trick has no winning play, no points and no two-of-trump owner.

  ## Examples

      iex> trick = %Pidro.Core.Types.Trick{number: 1, leader: :north, plays: [{:north, {2, :hearts}}]}
      iex> Pidro.Finnish.Scorer.trick_signals(trick, :hearts, :finnish)
      %{winning: %{position: :north, card: {2, :hearts}}, points: 0, two_of_trump: %{position: :north, points: 1}}
  """
  @spec trick_signals(Types.Trick.t(), suit(), atom()) :: %{
          winning: %{position: position(), card: Types.card()} | nil,
          points: non_neg_integer(),
          two_of_trump: %{position: position(), points: non_neg_integer()} | nil
        }
  def trick_signals(%Types.Trick{plays: []}, _trump_suit, _variant) do
    %{winning: nil, points: 0, two_of_trump: nil}
  end

  def trick_signals(%Types.Trick{} = trick, trump_suit, variant) do
    score = score_trick(trick, trump_suit, variant)
    {position, card} = List.keyfind(trick.plays, score.winner, 0)

    two_of_trump =
      case score.two_of_trump_player do
        nil -> nil
        player -> %{position: player, points: score.two_of_trump_points}
      end

    %{
      winning: %{position: position, card: card},
      points: score.winner_points,
      two_of_trump: two_of_trump
    }
  end

  @doc """
  Aggregates team scores from all scored tricks in a hand.

  This function takes all the trick scores (from `score_trick/2`) and
  calculates the total points for each team, accounting for:
  - Points won by trick winners
  - Points kept by players who played the 2 of trump

  ## Parameters
  - `scored_tricks` - List of trick score maps from `score_trick/2`

  ## Returns
  A map with team scores: `%{north_south: points, east_west: points}`

  ## Examples

      iex> tricks = [
      ...>   %{winner: :north, winner_points: 5, two_of_trump_player: nil, two_of_trump_points: 0},
      ...>   %{winner: :east, winner_points: 7, two_of_trump_player: nil, two_of_trump_points: 0},
      ...>   %{winner: :south, winner_points: 1, two_of_trump_player: :west, two_of_trump_points: 1}
      ...> ]
      iex> Pidro.Finnish.Scorer.aggregate_team_scores(tricks)
      %{north_south: 6, east_west: 8}  # NS: 5+1, EW: 7+1

      iex> tricks = [
      ...>   %{winner: :north, winner_points: 6, two_of_trump_player: :north, two_of_trump_points: 1},
      ...>   %{winner: :east, winner_points: 7, two_of_trump_player: nil, two_of_trump_points: 0}
      ...> ]
      iex> Pidro.Finnish.Scorer.aggregate_team_scores(tricks)
      %{north_south: 7, east_west: 7}  # NS: 6+1 (same player), EW: 7
  """
  @spec aggregate_team_scores([trick_score()]) :: %{team() => non_neg_integer()}
  def aggregate_team_scores(scored_tricks) do
    initial_scores = %{north_south: 0, east_west: 0}

    Enum.reduce(scored_tricks, initial_scores, fn trick_score, acc ->
      # Add winner's points to their team
      winner_team = Types.position_to_team(trick_score.winner)
      acc = Map.update!(acc, winner_team, &(&1 + trick_score.winner_points))

      # Add 2 of trump points to the player's team who played it (if any)
      case trick_score.two_of_trump_player do
        nil ->
          acc

        player ->
          player_team = Types.position_to_team(player)
          Map.update!(acc, player_team, &(&1 + trick_score.two_of_trump_points))
      end
    end)
  end

  @doc """
  Lists every card that scored in the given tricks, with the seat that took it.

  Attribution follows `score_trick/3`: the trick winner takes each point card,
  except the 2 of trump, which its player keeps. Each team's points add up to
  its `aggregate_team_scores/1` total.

  ## Examples

      iex> trick = %Pidro.Core.Types.Trick{
      ...>   number: 1,
      ...>   leader: :north,
      ...>   plays: [{:north, {14, :hearts}}, {:east, {2, :hearts}}, {:south, {7, :hearts}}]
      ...> }
      iex> Pidro.Finnish.Scorer.point_cards([trick], :hearts)
      [
        %{card: {14, :hearts}, points: 1, position: :north, team: :north_south},
        %{card: {2, :hearts}, points: 1, position: :east, team: :east_west}
      ]
  """
  @spec point_cards([Types.Trick.t()], suit(), atom()) :: [point_card()]
  def point_cards(tricks, trump_suit, variant \\ :finnish) do
    for trick <- tricks,
        score = score_trick(trick, trump_suit, variant),
        {player, card} <- trick.plays,
        points = Card.point_value(card, trump_suit),
        points > 0 do
      position = if player == score.two_of_trump_player, do: player, else: score.winner
      %{card: card, points: points, position: position, team: Types.position_to_team(position)}
    end
  end

  @doc """
  Applies bid result to cumulative scores based on hand outcome.

  This implements the core Finnish Pidro scoring rules:

  **Bidding Team:**
  - Made bid (points >= bid): add points taken to score
  - Failed bid (points < bid): subtract bid amount from score (can go negative)

  **Defending Team:**
  - Always add points taken to score

  ## Parameters
  - `state` - `GameState.t()` with completed hand and `hand_points` calculated

  ## Returns
  Updated `GameState.t()` with:
  - `cumulative_scores` updated with bid results
  - `events` with `:hand_scored` events added

  ## Examples

      See the test suite for comprehensive examples of:
      - Bidding team making their bid
      - Bidding team failing their bid
      - Edge cases like exact bids and negative scores
  """
  @spec apply_bid_result(Types.GameState.t()) :: Types.GameState.t()
  def apply_bid_result(%Types.GameState{} = state) do
    {bidder_position, bid_amount} = state.highest_bid
    bidding_team = state.bidding_team
    defending_team = Types.opposing_team(bidding_team)

    bidding_points = Map.get(state.hand_points, bidding_team, 0)
    defending_points = Map.get(state.hand_points, defending_team, 0)

    old_scores = state.cumulative_scores
    made = bidding_points >= bid_amount

    {new_bidding_score, new_defending_score} =
      if made do
        # Bidding team made their bid - both teams get their points
        {
          old_scores[bidding_team] + bidding_points,
          old_scores[defending_team] + defending_points
        }
      else
        # Bidding team failed - they lose bid amount, defenders get their points
        {
          old_scores[bidding_team] - bid_amount,
          old_scores[defending_team] + defending_points
        }
      end

    # Update cumulative scores
    new_cumulative_scores =
      old_scores
      |> Map.put(bidding_team, new_bidding_score)
      |> Map.put(defending_team, new_defending_score)

    # Create scoring events
    bidding_delta = new_bidding_score - old_scores[bidding_team]
    defending_delta = new_defending_score - old_scores[defending_team]

    bidding_event = {:hand_scored, bidding_team, bidding_delta}
    defending_event = {:hand_scored, defending_team, defending_delta}

    last_hand = %{
      hand_number: state.hand_number,
      bidding_team: bidding_team,
      bidder: bidder_position,
      bid: bid_amount,
      captured: state.hand_points,
      made: made,
      delta: %{bidding_team => bidding_delta, defending_team => defending_delta},
      scores: new_cumulative_scores,
      point_cards: point_cards(state.tricks, state.trump_suit, state.variant),
      # The hand-complete reset clears these from the live state in the same
      # transition, so the finished hand is kept here for clients to read back.
      bids: state.bids,
      trump: state.trump_suit,
      tricks: state.tricks
    }

    # Update state
    state
    |> GameState.update(:cumulative_scores, new_cumulative_scores)
    |> GameState.update(:last_hand, last_hand)
    |> GameState.update(:hand_history, state.hand_history ++ [hand_summary(last_hand)])
    |> GameState.update(:events, state.events ++ [bidding_event, defending_event])
  end

  @doc """
  Checks if the game is over (any team reached 62 points).

  ## Parameters
  - `state` - `GameState.t()` with current cumulative scores

  ## Returns
  - `true` if any team has >= 62 points
  - `false` otherwise

  ## Examples

      See test suite for examples.
  """
  @spec game_over?(Types.GameState.t()) :: boolean()
  def game_over?(%Types.GameState{cumulative_scores: scores, config: config}) do
    Enum.any?(scores, fn {_team, score} -> score >= config.winning_score end)
  end

  @doc """
  Determines the winning team if the game is over.

  If both teams reach 62 points on the same hand (which is possible),
  the bidding team wins according to Finnish Pidro rules.

  ## Parameters
  - `state` - `GameState.t()` with current cumulative scores and bidding info

  ## Returns
  - `{:ok, team}` if game is over and there's a winner
  - `{:error, :game_not_over}` if no team has reached 62 points

  ## Examples

      See test suite for examples including:
      - Clear winner scenarios
      - Both teams at 62 (bidding team wins)
      - Game not over cases
  """
  @spec determine_winner(Types.GameState.t()) :: {:ok, team()} | {:error, :game_not_over}
  def determine_winner(
        %Types.GameState{cumulative_scores: scores, bidding_team: bidding_team} = state
      ) do
    if game_over?(state) do
      ns_score = scores.north_south
      ew_score = scores.east_west
      target = state.config.winning_score

      winner =
        cond do
          # Both teams at 62+ - bidding team wins
          ns_score >= target and ew_score >= target ->
            bidding_team

          # Only one team at 62+
          ns_score >= target ->
            :north_south

          ew_score >= target ->
            :east_west
        end

      {:ok, winner}
    else
      {:error, :game_not_over}
    end
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  # A hand_history entry is the last hand without its bids and tricks.
  @spec hand_summary(map()) :: map()
  defp hand_summary(last_hand), do: Map.drop(last_hand, [:bids, :tricks])

  # Finds if the 2 of trump was played in this trick
  # Returns {player_position, 1} if found, nil otherwise
  @spec find_two_of_trump([{position(), card()}], suit()) :: {position(), 1} | nil
  defp find_two_of_trump(plays, trump_suit) do
    case Enum.find(plays, fn {_pos, {rank, suit}} ->
           rank == 2 and suit == trump_suit
         end) do
      {player, _card} -> {player, 1}
      nil -> nil
    end
  end
end
