# Getting Started with Pidro Engine

This guide will help you get up and running with the Pidro game engine, from basic setup to playing your first game.

## Installation

Add `pidro_engine` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pidro_engine, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Your First Game in IEx

The fastest way to understand Pidro is to play it interactively in IEx:

### 1. Start IEx

```bash
cd apps/pidro_engine
iex -S mix
```

### 2. Import Helpers

```elixir
import Pidro.IEx
```

### 3. Create a Game

```elixir
state = new_game()
```

This creates a complete game with:
- Deck shuffled
- Dealer selected via cutting
- 9 cards dealt to each player
- Game in bidding phase, ready to play

### 4. View the Game

```elixir
pretty_print(state)
```

You'll see a beautiful display showing:
- Current phase and hand number
- Dealer and current turn
- Each player's hand with cards
- Scores for both teams
- Trump indicators (★) on cards

### 5. See Available Actions

```elixir
show_legal_actions(state, state.current_turn)
```

This shows all valid moves for the current player.

### 6. Make a Move

```elixir
{:ok, state} = step(state, state.current_turn, {:bid, 10})
```

The `step/3` function:
- Applies the action
- Shows what happened
- Displays the updated game state
- Returns the new state

### 7. Continue Playing

```elixir
# Complete the bidding round
{:ok, state} = step(state, :north, :pass)
{:ok, state} = step(state, :east, {:bid, 11})
{:ok, state} = step(state, :south, :pass)
{:ok, state} = step(state, :west, :pass)

# Declare trump
{:ok, state} = step(state, :east, {:declare_trump, :hearts})

# Game automatically:
# 1. Discards all non-trump cards
# 2. Deals remaining cards to players (up to 6 each)
# 3. Dealer robs the pack (takes remaining cards, selects best 6)
# 4. Transitions to playing phase

# Play cards
{:ok, state} = step(state, state.current_turn, {:play_card, {14, :hearts}})
# ... continue playing
```

### 8. Run an Automated Demo

```elixir
demo_game()
```

This runs through an entire game automatically, pausing at each phase so you can see what's happening.

## Using the Core Engine

For programmatic use without the IEx helpers:

```elixir
alias Pidro.Game.Engine
alias Pidro.Core.{GameState, Types}

# Create a new game. `:seed` is required — it is the game's chance stream,
# and every card the game deals follows from it. `Pidro.Server` generates one
# per live game; pass your own to get a reproducible game.
state = GameState.new(seed: 1)

# Run the dealer-cut ceremony and deal the first hand
{:ok, state} = Engine.apply_action(state, :north, :select_dealer)
{:ok, state} = Engine.advance_from_dealer_selection(state)

# Get legal actions
actions = Engine.legal_actions(state, :north)
# => [{:bid, 6}, {:bid, 7}, ..., {:bid, 14}, :pass]

# Apply an action
{:ok, new_state} = Engine.apply_action(state, :north, {:bid, 8})

# Check what phase we're in
state.phase  # => :bidding

# Access player hands
player = state.players[:north]
player.hand  # => [{14, :hearts}, {10, :clubs}, ...]
```

## Using the OTP Server

For production use with GenServer:

```elixir
# Start the supervisor (automatically started in applications)
{:ok, _pid} = Pidro.Supervisor.start_link([])

# Start a game. With no `:seed`, the server generates fresh entropy from
# `:crypto.strong_rand_bytes/1` — this is the only place in the production
# path that does. Pass `seed: 7` instead and the game, and every `reset/1` of
# it, deals the identical cards.
{:ok, game_pid} = Pidro.Supervisor.start_game(game_id: "game-123", register: true)

# Apply actions
{:ok, state} = Pidro.Server.apply_action(game_pid, :north, {:bid, 8})

# Get current state
state = Pidro.Server.get_state(game_pid)

# Get legal actions
actions = Pidro.Server.legal_actions(game_pid, :north)

# Check if game is over
if Pidro.Server.game_over?(game_pid) do
  winner = Pidro.Server.winner(game_pid)
  IO.puts("Winner: #{winner}")
end

# Get full event history
history = Pidro.Server.get_history(game_pid)

# Stop the game
Pidro.Supervisor.stop_game(game_pid)
```

## Understanding Game Flow

A Finnish Pidro game follows this sequence:

1. **Dealer Selection** - Players cut cards, highest becomes dealer
2. **Initial Deal** - 9 cards dealt to each player in 3-card batches
3. **Bidding** - Players bid or pass, starting left of dealer
4. **Trump Declaration** - Bid winner declares trump suit
5. **Discard** - All non-trump cards automatically discarded
6. **Second Deal** - Players dealt cards to reach 6 (if they have <6 trump)
7. **Dealer Rob** - Dealer takes remaining deck, selects best 6 cards
8. **Kill Rule** - Players with >6 trump must discard non-point cards
9. **Playing** - Tricks played (only trump cards valid)
10. **Going Cold** - Players eliminated when out of trumps
11. **Scoring** - Points tallied, bid checked, cumulative scores updated
12. **Next Hand** - Dealer rotates, repeat until team reaches 62

## Key Concepts

### Positions and Teams

- **Positions**: `:north`, `:east`, `:south`, `:west`
- **Teams**:
  - `:north_south` (North and South are partners)
  - `:east_west` (East and West are partners)

### Cards

Cards are represented as `{rank, suit}` tuples:
- **Rank**: 2-14 (2-10, Jack=11, Queen=12, King=13, Ace=14)
- **Suit**: `:hearts`, `:diamonds`, `:clubs`, `:spades`

Examples:
- `{14, :hearts}` - Ace of hearts
- `{11, :clubs}` - Jack of clubs
- `{5, :diamonds}` - 5 of diamonds

### The Wrong 5 Rule

The 5 of the same-color suit is considered trump:
- If hearts is trump, 5 of diamonds is trump (wrong 5)
- If clubs is trump, 5 of spades is trump (wrong 5)

This means each hand has **15 trump cards** (14 of trump suit + 1 wrong 5).

### Actions

Different phases accept different actions:

**Bidding Phase:**
- `{:bid, amount}` - Bid 6-14 points
- `:pass` - Pass on bidding

**Declaring Phase:**
- `{:declare_trump, suit}` - Declare trump suit

**Dealer Rob Phase:**
- `{:select_cards, [card, card, ...]}` - Select 6 cards from pool

**Playing Phase:**
- `{:play_card, card}` - Play a trump card

## Next Steps

- Read [Game Rules](game_rules.md) for complete Finnish Pidro rules
- See [Architecture](architecture.md) to understand the engine design
- Explore [Property Testing](property_testing.md) to see how correctness is ensured
- Learn about [Event Sourcing](event_sourcing.md) for replay and undo

## Common Patterns

### Check Phase Before Action

```elixir
case state.phase do
  :bidding -> # show bid options
  :declaring -> # show trump selection
  :playing -> # show playable cards
  :complete -> # game over
  _ -> # other phases are automatic
end
```

### Handle Errors

```elixir
case Engine.apply_action(state, position, action) do
  {:ok, new_state} ->
    # Success
  {:error, :not_your_turn} ->
    # Wrong player
  {:error, :invalid_action} ->
    # Invalid move
  {:error, reason} ->
    # Other error
end
```

### Track Game Events

```elixir
# Events are automatically tracked
state.events
# => [
#   {:dealer_selected, :south, {10, :clubs}},
#   {:cards_dealt, %{...}},
#   {:bid_made, :west, 10},
#   ...
# ]

# Use for replay, undo, or logging
```

## Troubleshooting

**Q: Why can't I play a card in the bidding phase?**

A: Each phase only accepts specific actions. Use `state.phase` to check the current phase and `legal_actions/2` to see valid moves.

**Q: Why does my player have 0 cards after trump declaration?**

A: If a player has no trump cards (including wrong 5), all their cards are discarded during the automatic discard phase. They'll be "cold" and not participate in trick-taking.

**Q: What if all players pass during bidding?**

A: The dealer is forced to bid 6 (minimum bid).

**Q: Can the dealer have more than 6 cards?**

A: No. After robbing the pack the dealer keeps exactly 6 cards (the whole pool, if it holds fewer) and discards the rest face down.

## Example Complete Game

See [EXAMPLE_SESSION.md](../EXAMPLE_SESSION.md) for a complete walkthrough of a game from start to finish.
