# Property-Based Testing Guide

This guide explains how property-based testing ensures correctness in the Pidro engine.

## What is Property-Based Testing?

Instead of writing individual test examples, you define **properties** (invariants that should always hold) and the test framework generates hundreds of random test cases.

### Example-Based Testing (Traditional)

```elixir
test "ace of hearts beats king of hearts" do
  assert Card.compare({14, :hearts}, {13, :hearts}, :hearts) == :gt
end

test "king of hearts beats queen of hearts" do
  assert Card.compare({13, :hearts}, {12, :hearts}, :hearts) == :gt
end

# ... need many more examples
```

**Problem**: Only tests specific cases you think of.

### Property-Based Testing

```elixir
property "trump ranking is transitive" do
  check all card1 <- card_generator(),
            card2 <- card_generator(),
            card3 <- card_generator(),
            trump <- suit_generator() do

    # If card1 > card2 AND card2 > card3, then card1 > card3
    if Card.compare(card1, card2, trump) == :gt and
       Card.compare(card2, card3, trump) == :gt do
      assert Card.compare(card1, card3, trump) == :gt
    end
  end
end
```

**Benefit**: Tests thousands of random combinations automatically.

## Our Property Testing Setup

### Framework: StreamData

We use [StreamData](https://github.com/whatyouhide/stream_data) for property-based testing:

```elixir
use ExUnitProperties

property "description" do
  check all input <- generator() do
    # assertion
  end
end
```

### Test Statistics

- **157 properties** across all modules
- **50-100 runs** per property (default)
- **123 property checks** in test suite
- **0 failures** (all properties hold)

## Core Properties

### Card Properties

**Property: Trump ranking is transitive**

```elixir
property "card comparison is transitive" do
  check all card1 <- card_generator(),
            card2 <- card_generator(),
            card3 <- card_generator(),
            trump <- suit_generator() do

    cmp_12 = Card.compare(card1, card2, trump)
    cmp_23 = Card.compare(card2, card3, trump)
    cmp_13 = Card.compare(card1, card3, trump)

    # If a > b and b > c, then a > c
    if cmp_12 == :gt and cmp_23 == :gt do
      assert cmp_13 == :gt
    end
  end
end
```

**Property: Right 5 always beats Wrong 5**

```elixir
property "right pidro always beats wrong pidro" do
  check all trump <- suit_generator() do
    right_five = {5, trump}
    wrong_five = {5, Card.same_color_suit(trump)}

    assert Card.compare(right_five, wrong_five, trump) == :gt
  end
end
```

**Property: Point distribution**

```elixir
property "point distribution is exactly 14 per hand" do
  check all trump <- suit_generator() do
    point_cards = [
      {14, trump},  # A = 1
      {11, trump},  # J = 1
      {10, trump},  # 10 = 1
      {5, trump},   # Right 5 = 5
      {5, Card.same_color_suit(trump)},  # Wrong 5 = 5
      {2, trump}    # 2 = 1
    ]

    total = Enum.sum(Enum.map(point_cards, &Card.point_value(&1, trump)))
    assert total == 14
  end
end
```

### Deck Properties

**Property: Deck always has 52 cards**

```elixir
property "deck always contains exactly 52 cards" do
  check all seed <- integer(1..1_000_000) do
    {cards, _chance} = Chance.shuffle(Deck.ordered(), Chance.from_seed(seed))
    assert length(cards) == 52
  end
end
```

**Property: Each suit has exactly 13 cards**

```elixir
property "each suit contains exactly 13 cards" do
  check all seed <- integer(1..1_000_000) do
    {cards, _chance} = Chance.shuffle(Deck.ordered(), Chance.from_seed(seed))

    Enum.each([:hearts, :diamonds, :clubs, :spades], fn suit ->
      count = Enum.count(cards, fn {_rank, s} -> s == suit end)
      assert count == 13
    end)
  end
end
```

### Game Flow Properties

**Property: Phases transition in order**

```elixir
property "game phases transition in correct order" do
  check all game <- game_flow_generator() do
    phases = Enum.map(game.events, fn
      {:phase_transitioned, _from, to} -> to
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)

    expected_order = [
      :dealer_selection,
      :dealing,
      :bidding,
      :declaring,
      :discarding,
      :second_deal,
      :playing,
      :scoring
    ]

    # Phases should appear in expected order
    assert phases_in_order?(phases, expected_order)
  end
end
```

**Property: Exactly 4 players in every game**

```elixir
property "exactly 4 players in every game" do
  check all state <- game_state_generator() do
    assert map_size(state.players) == 4
    assert MapSet.new(Map.keys(state.players)) ==
           MapSet.new([:north, :east, :south, :west])
  end
end
```

### Bidding Properties

**Property: Bid must be higher than current**

```elixir
property "bid must be higher than current bid" do
  check all state <- bidding_phase_generator(),
            position <- position_generator(),
            bid <- integer(6..14) do

    result = Bidding.validate_bid(state, position, bid)

    if state.highest_bid != nil and bid <= state.highest_bid do
      assert result == {:error, :bid_too_low}
    end
  end
end
```

**Property: If all pass, dealer must bid 6**

```elixir
property "if all players pass, dealer must bid 6" do
  check all state <- all_passed_generator() do
    dealer = state.current_dealer
    result = Bidding.apply_pass(state, dealer)

    # Dealer cannot pass if all others passed
    assert result == {:error, :dealer_must_bid_minimum}

    # Dealer forced to bid 6
    {:ok, new_state} = Bidding.apply_bid(state, dealer, 6)
    assert new_state.highest_bid == 6
    assert new_state.highest_bidder == dealer
  end
end
```

### Redeal Properties

**Property: Dealer combines hand + deck**

```elixir
property "dealer combines hand + remaining deck before selecting 6" do
  check all state <- pre_dealer_rob_generator() do
    dealer = state.current_dealer
    dealer_hand_size = length(state.players[dealer].hand)
    deck_size = length(state.deck)

    expected_pool_size = dealer_hand_size + deck_size

    {:ok, new_state} = Discard.dealer_rob_pack(state, dealer)

    assert new_state.dealer_pool_size == expected_pool_size
    assert expected_pool_size >= 6
  end
end
```

**Property: Killed cards are non-point trump**

```elixir
property "killed cards must be non-point trumps" do
  check all state <- post_redeal_generator() do
    Enum.all?(state.killed_cards, fn {pos, killed} ->
      trump = state.trump_suit

      Enum.all?(killed, fn card ->
        Card.is_trump?(card, trump) and
        not Card.is_point_card?(card, trump)
      end)
    end)
  end
end
```

### Play Phase Properties

**Property: Only trump cards are valid plays**

```elixir
property "only trump cards are valid plays" do
  check all state <- playing_phase_generator(),
            position <- active_position_generator(state),
            card <- card_generator() do

    result = Play.validate_play(state, position, card)
    trump = state.trump_suit

    if not Card.is_trump?(card, trump) do
      assert result == {:error, :must_play_trump}
    end
  end
end
```

**Property: Highest trump wins**

```elixir
property "highest trump card wins the trick" do
  check all trick <- complete_trick_generator(),
            trump <- suit_generator() do

    winner = Trick.winner(trick, trump)
    winning_card = trick.plays
                   |> Enum.find(fn {pos, _card} -> pos == winner end)
                   |> elem(1)

    # Winning card should beat all other cards
    Enum.all?(trick.plays, fn {_pos, card} ->
      Card.compare(winning_card, card, trump) in [:gt, :eq]
    end)
  end
end
```

### Scoring Properties

**Property: Total points equals 14**

```elixir
property "total points in hand equals 14" do
  check all state <- scored_game_generator() do
    team1_points = get_in(state.cumulative_scores, [:north_south])
    team2_points = get_in(state.cumulative_scores, [:east_west])

    # Point cards are never killed, so killing removes no points.
    # If no failed bid, sum should equal 14
    if no_failed_bid?(state) do
      assert team1_points + team2_points == 14
    end
  end
end
```

### Determinism Properties

These are unusual in that the generated input is a **seed** rather than a
state: the engine's randomness is an explicit field on `%GameState{}`, so a
seed names a whole game. They also do something no other property here does —
they deliberately draw from the *test* process's `:rand` dictionary between two
otherwise identical engine calls, to assert it changes nothing.

**Property: transitions ignore the caller's RNG**

```elixir
property "the dealer-cut transition ignores the caller's RNG" do
  check all seed <- integer(1..1_000_000), max_runs: 100 do
    state = GameState.new(seed: seed)

    {:ok, first} = Engine.apply_action(state, :north, :select_dealer)

    _ = Enum.shuffle(1..100)
    _ = :rand.uniform(1_000_000)

    {:ok, second} = Engine.apply_action(state, :north, :select_dealer)

    assert first == second
  end
end
```

See `test/properties/determinism_properties_test.exs` and
`test/properties/continuation_properties_test.exs`. Two example-based tests sit
alongside them because they cannot be expressed as properties:
`test/unit/core/chance_containment_test.exs` scans the domain's sources for any
path back to the process RNG, and `test/unit/core/chance_vector_test.exs`
records one seed's exact output so an OTP or `Chance` change is a loud failure.

## Writing Custom Generators

### Basic Generators

```elixir
defmodule Pidro.TestSupport.Generators do
  import StreamData

  def card_generator do
    tuple({rank_generator(), suit_generator()})
  end

  def rank_generator do
    integer(2..14)
  end

  def suit_generator do
    member_of([:hearts, :diamonds, :clubs, :spades])
  end

  def position_generator do
    member_of([:north, :east, :south, :west])
  end
end
```

### Complex State Generators

```elixir
def bidding_phase_generator do
  bind(integer(), fn seed ->
    # Generate game through dealer selection and dealing
    {:ok, state} = Engine.new_game(seed)

    # Now in bidding phase
    constant(state)
  end)
end

def playing_phase_generator do
  bind(bidding_phase_generator(), fn state ->
    # Complete bidding
    state = simulate_bidding(state)

    # Declare trump
    {:ok, state} = Engine.apply_action(
      state,
      state.highest_bidder,
      {:declare_trump, :hearts}
    )

    # Auto-phases complete, now in playing
    constant(state)
  end)
end
```

### Constrained Generators

```elixir
def valid_bid_generator(current_highest) do
  if current_highest == nil do
    integer(6..14)
  else
    # Must be higher than current
    integer((current_highest + 1)..14)
  end
end

def trump_card_generator(trump_suit) do
  bind(rank_generator(), fn rank ->
    # Either trump suit or wrong 5
    if rank == 5 do
      member_of([
        {5, trump_suit},
        {5, Card.same_color_suit(trump_suit)}
      ])
    else
      constant({rank, trump_suit})
    end
  end)
end
```

## Property Test Best Practices

### 1. Test Invariants, Not Procedures

❌ **Bad**: Test specific execution path

```elixir
property "bidding works" do
  check all state <- new_game_generator() do
    {:ok, s1} = Engine.apply_action(state, :west, {:bid, 10})
    {:ok, s2} = Engine.apply_action(s1, :north, :pass)
    # ... etc
  end
end
```

✅ **Good**: Test invariants that always hold

```elixir
property "highest bid always increases or stays same" do
  check all state <- bidding_phase_generator(),
            action <- valid_bidding_action_generator(state) do

    {:ok, new_state} = Engine.apply_action(state, state.current_turn, action)

    assert new_state.highest_bid >= (state.highest_bid || 0)
  end
end
```

### 2. Use Generators Wisely

Generate **valid** inputs, not random garbage:

❌ **Bad**: Generate any integer

```elixir
property "bid validation" do
  check all bid <- integer() do
    # Will generate -999999, 0, 1000000, etc.
    # Most will be invalid, test is noisy
  end
end
```

✅ **Good**: Generate valid range

```elixir
property "bid validation" do
  check all bid <- integer(6..14) do
    # Only generates valid bid range
  end
end
```

### 3. Shrinking

When a property fails, StreamData "shrinks" the input to find the minimal failing case:

```elixir
property "example shrinking" do
  check all list <- list_of(integer()) do
    # Fails for [5, 0, 3]
    # Shrinks to minimal: [0]
    assert Enum.all?(list, &(&1 > 0))
  end
end
```

StreamData automatically finds the simplest failing case.

### 4. Check Preconditions

Use `filter/2` or guards to ensure valid test data:

```elixir
property "dealer rob selection" do
  check all state <- game_state_generator(),
            # Filter: only states where dealer_rob is possible
            filter(fn s -> s.phase == :second_deal and length(s.deck) > 0 end) do

    {:ok, new_state} = Discard.dealer_rob_pack(state)
    assert length(new_state.players[state.current_dealer].hand) == 6
  end
end
```

## Common Property Patterns

### Roundtrip Properties

```elixir
property "encoding roundtrip preserves state" do
  check all state <- game_state_generator() do
    encoded = Notation.encode(state)
    {:ok, decoded} = Notation.decode(encoded)

    assert states_equal?(state, decoded)
  end
end
```

### Commutativity

```elixir
property "scoring is commutative within teams" do
  check all tricks <- list_of(trick_generator()) do
    # Order of tricks shouldn't matter for final team score
    score1 = score_tricks(tricks)
    score2 = score_tricks(Enum.reverse(tricks))

    assert score1 == score2
  end
end
```

### Idempotence

```elixir
property "applying same event twice has no effect" do
  check all state <- game_state_generator(),
            event <- event_generator() do

    state1 = Events.apply_event(state, event)
    state2 = Events.apply_event(state1, event)

    # Second application should be no-op (for idempotent events)
    assert state1 == state2
  end
end
```

## Running Property Tests

### Run All Tests

```bash
mix test
```

### Run Only Property Tests

```bash
mix test --only property
```

### Increase Iterations

```bash
# Run 1000 iterations per property
MAX_RUNS=1000 mix test
```

### Debug Failing Property

```elixir
property "example" do
  check all input <- generator(),
            # Print generated values
            tap(IO.inspect/1) do

    # Your assertion
  end
end
```

## Benefits for Pidro Engine

Property-based testing has been invaluable for Pidro:

1. **Caught Edge Cases**: Found dealer rob bug when all non-dealers request 6 cards
2. **Ensures Correctness**: 157 properties prove game rules always hold
3. **Regression Prevention**: Properties catch bugs introduced by new features
4. **Documentation**: Properties describe what the system should do
5. **Confidence**: Can refactor freely knowing properties will catch breakage

## Next Steps

- Read [Event Sourcing](event_sourcing.md) to understand replay mechanics
- See [Architecture](architecture.md) for overall system design
- Explore `test/properties/` directory for all properties
- Read [StreamData documentation](https://hexdocs.pm/stream_data)

## Further Reading

- [Property-Based Testing with PropEr, Erlang, and Elixir](https://propertesting.com/) by Fred Hebert
- [StreamData documentation](https://hexdocs.pm/stream_data)
- [QuickCheck paper](https://www.cs.tufts.edu/~nr/cs257/archive/john-hughes/quick.pdf) (original PBT paper)
