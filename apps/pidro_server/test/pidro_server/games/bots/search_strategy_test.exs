defmodule PidroServer.Games.Bots.SearchStrategyTest do
  use ExUnit.Case, async: true

  alias Pidro.Core.{GameState, SeatView}
  alias Pidro.Core.Types.Bid
  alias PidroServer.Games.Bots.Strategies.{RulebookStrategy, SearchStrategy}

  # docs/bot-search-disagreements.md, shape 6: "West to bid, East deals,
  # score us 22, them 13. Bids: South pass. Hand: 4♥ 5♥ 6♦ 3♠ 3♣ 4♠ 3♥ 9♥ 6♠."
  @hand [{4, :hearts}, {5, :hearts}, {6, :diamonds}, {3, :spades}, {3, :clubs}] ++
          [{4, :spades}, {3, :hearts}, {9, :hearts}, {6, :spades}]

  defp west_to_bid do
    deck = for suit <- [:hearts, :diamonds, :clubs, :spades], rank <- 2..14, do: {rank, suit}
    others = Enum.zip([:north, :east, :south], Enum.chunk_every(deck -- @hand, 9))
    hands = Map.new([{:west, @hand} | others])
    base = GameState.new(seed: 1)

    state = %{
      base
      | players: Map.new(base.players, fn {pos, p} -> {pos, %{p | hand: hands[pos]}} end),
        phase: :bidding,
        current_dealer: :east,
        current_turn: :west,
        bids: [%Bid{position: :south, amount: :pass, timestamp: 0}],
        cumulative_scores: %{east_west: 22, north_south: 13}
    }

    {SeatView.for_seat(state, :west), Pidro.Game.Engine.legal_actions(state, :west)}
  end

  test "where search and the rulebook disagree, each adapter plays its own move" do
    {view, legal} = west_to_bid()

    assert {:ok, :pass, rulebook_reason} = RulebookStrategy.pick_action(legal, view)
    refute rulebook_reason =~ "search"

    assert {:ok, {:bid, 6}, reason} = SearchStrategy.pick_action(legal, view)
    assert reason =~ ~r/^Rulebook says pass; search makes 6 in \d+% of worlds, so bid 6\.$/
  end

  test "the same position decides the same way every time" do
    {view, legal} = west_to_bid()
    assert SearchStrategy.pick_action(legal, view) == SearchStrategy.pick_action(legal, view)
  end
end
