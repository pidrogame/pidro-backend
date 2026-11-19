# Pidro Engine

A pure functional Finnish Pidro card game engine built with Elixir, featuring event sourcing, comprehensive property-based testing, and interactive IEx helpers.

## Features

- **Pure Functional Core** - Immutable game state; randomness is an explicit input, so the same state and action give the same result
- **Event Sourcing** - Full event log, undo/redo support, PGN-like notation
- **Finnish Variant** - Full implementation of Finnish Pidro rules including redeal mechanics
- **Property-Based Testing** - 157 properties ensuring correctness across all game phases
- **Interactive Development** - Rich IEx helpers for playing games in the console
- **OTP Integration** - GenServer wrapper ready for Phoenix integration
- **Performance Optimized** - Move caching, binary encoding, fast state hashing

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:pidro_engine, "~> 0.1.0"}
  ]
end
```

### Play in IEx

```bash
cd apps/pidro_engine
iex -S mix
```

```elixir
# Import the IEx helpers
import Pidro.IEx

# Create a new game (dealer selected, ready for bidding)
state = new_game()

# View the game state beautifully formatted
pretty_print(state)

# See what actions are available
show_legal_actions(state, :west)

# Make a move
{:ok, state} = step(state, :west, {:bid, 10})

# Continue playing...
{:ok, state} = step(state, :north, :pass)
{:ok, state} = step(state, :east, {:bid, 11})

# Run an automated demo game
demo_game()
```

### Use the Game Engine

```elixir
alias Pidro.Game.Engine
alias Pidro.Core.GameState

# Create a new game. The seed is the game's chance stream and is required —
# there is no default. `Pidro.Server` generates one for live games.
state = GameState.new(seed: 1)
{:ok, state} = Engine.apply_action(state, :north, :select_dealer)
{:ok, state} = Engine.advance_from_dealer_selection(state)

# Get legal actions for a position
actions = Engine.legal_actions(state, :north)

# Apply an action
{:ok, new_state} = Engine.apply_action(state, :north, {:bid, 8})

# Check game phase
state.phase  # :bidding, :playing, :scoring, etc.
```

### Use the OTP Server

```elixir
# Start a supervised game. Omit `:seed` and the server generates fresh
# entropy; pass one to get a reproducible game.
{:ok, pid} = Pidro.Supervisor.start_game(game_id: "game-123", register: true)

# Apply actions through the server
{:ok, state} = Pidro.Server.apply_action(pid, :north, {:bid, 8})

# Get current state
state = Pidro.Server.get_state(pid)

# Check if game is over
Pidro.Server.game_over?(pid)
```

## Game Rules Overview

Finnish Pidro is a trick-taking card game for 4 players in 2 teams:

- **Teams**: North/South vs East/West (partners sit opposite)
- **Initial Deal**: 9 cards per player
- **Bidding**: Players bid 6-14 points (or pass)
- **Trump Declaration**: Bid winner declares trump suit
- **Redeal**: Non-trump cards discarded, players dealt to 6 cards
- **Dealer Rob**: Dealer combines hand + remaining deck, selects best 6
- **Kill Rule**: Players with >6 trump must discard non-point cards
- **Play**: Only trump cards can be played
- **Going Cold**: Players with no trumps are eliminated from the hand
- **Scoring**: 14 points per hand, first team to 62 wins

### Point Cards

- **Ace**: 1 point
- **Jack**: 1 point
- **10**: 1 point
- **Right 5** (5 of trump): 5 points
- **Wrong 5** (5 of same-color suit): 5 points
- **2**: 1 point

**Total**: 14 points per hand

### Trump Ranking

A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right-5 > Wrong-5 > 4 > 3 > 2

## Architecture

### Core Modules

- **Pidro.Core.Types** - Type definitions and GameState struct
- **Pidro.Core.Card** - Card operations, trump ranking, point values
- **Pidro.Core.Chance** - The explicit chance stream; the only module in the domain that touches `:rand`
- **Pidro.Core.Deck** - The 52 cards in a fixed generation order
- **Pidro.Core.Player** - Player state management
- **Pidro.Core.Trick** - Trick resolution and scoring
- **Pidro.Core.Events** - Event sourcing and replay

### Game Engine

- **Pidro.Game.Engine** - Main API: `apply_action/3`, `legal_actions/2`
- **Pidro.Game.StateMachine** - Phase transitions and validation
- **Pidro.Game.Dealing** - Dealer selection and card dealing
- **Pidro.Game.Bidding** - Bid validation and tracking
- **Pidro.Game.Trump** - Trump declaration and categorization
- **Pidro.Game.Discard** - Automatic discard, second deal, dealer rob
- **Pidro.Game.Play** - Trick-taking, elimination, kill rules
- **Pidro.Game.Replay** - Undo/redo, event replay

### Finnish Variant

- **Pidro.Finnish.Rules** - Finnish-specific rules
- **Pidro.Finnish.Scorer** - Scoring logic (bid made/failed)

### OTP Layer

- **Pidro.Server** - GenServer wrapper for game state
- **Pidro.Supervisor** - Supervision tree and game registry
- **Pidro.MoveCache** - ETS-based move generation cache

### Utilities

- **Pidro.IEx** - Interactive helpers for development
- **Pidro.Notation** - PGN-like game notation
- **Pidro.Perf** - Performance utilities (hashing, benchmarking)

## Development

### Running Tests

```bash
# All tests (unit + property tests)
mix test

# Type checking
mix dialyzer

# Code quality
mix credo --strict

# Test coverage
mix test --cover
```

### Test Statistics

- **516 tests** (375 unit + 141 property)
- **157 properties** testing game invariants
- **76 doctests** ensuring example accuracy
- **Zero failures** (except 1 flaky performance test)

### Interactive Development

See [IEX_HELPERS.md](IEX_HELPERS.md) for detailed documentation on:

- `new_game/0` - Create a ready-to-play game
- `pretty_print/1` - Beautiful game state visualization
- `show_event_log/1` - Complete event history
- `show_legal_actions/2` - Available moves
- `step/3` - Apply action and display result
- `demo_game/0` - Automated demonstration

See [EXAMPLE_SESSION.md](EXAMPLE_SESSION.md) for a complete walkthrough.

## Documentation

Generate and view full documentation:

```bash
mix docs
open doc/index.html
```

The documentation includes:

- **API Reference** - All modules, functions, and types
- **Guides** - Getting started, architecture, property testing, event sourcing
- **Specifications** - Complete Finnish Pidro rules and game properties
- **Development Docs** - Masterplan, implementation status, redeal mechanics

## Property-Based Testing

This engine uses extensive property-based testing with StreamData to ensure correctness:

### Core Properties

- Deck always contains exactly 52 cards
- Trump ranking is transitive and deterministic
- Right 5 always beats Wrong 5
- Point distribution is always exactly 14 per hand

### Game Flow Properties

- Phases transition in correct order
- Exactly 4 players in two opposing teams
- Dealer rotates correctly between hands
- Bidding completes with valid winner

### Redeal Mechanics Properties

- Dealer combines hand + deck before selecting 6
- Non-dealers receive correct number of cards
- Kill rule enforces non-point trump discards

See [guides/property_testing.md](guides/property_testing.md) for details.

## Event Sourcing

Every game action produces events that can be replayed:

```elixir
# Get event history
events = state.events

# Replay from events
{:ok, replayed_state} = Pidro.Game.Replay.replay(events)

# Undo last action
{:ok, previous_state} = Pidro.Game.Replay.undo(state)

# Export to PGN notation
pgn = Pidro.Notation.encode(state)

# Import from PGN
{:ok, imported_state} = Pidro.Notation.decode(pgn)
```

Replay and notation are both lossy: no event records the deck order, the
dealer-selection cuts, or the chance stream, so neither reconstructs a state a
game can be *continued* from. To save and resume a game, serialize the
`%GameState{}` itself — it is plain data and carries its own chance stream:

```elixir
saved = :erlang.term_to_binary(state)
resumed = :erlang.binary_to_term(saved)
```

See [guides/event_sourcing.md](guides/event_sourcing.md) for details.

## Performance

- **Card operations**: < 1μs
- **State hashing**: < 10μs
- **Move generation**: 2x+ speedup with cache
- **Full hand simulation**: ~50ms
- **Event replay**: ~100ms for complete game

Benchmark with:

```bash
mix run bench/pidro_benchmark.exs
```

## Implementation Status

- ✅ **Phase 0-11**: Core engine, event sourcing, performance layer, OTP wrapper
- ✅ **Redeal Mechanics**: Full Finnish variant with kill rules
- ✅ **Property Testing**: 157 properties covering all game phases
- ✅ **IEx Helpers**: Complete interactive development tools
- ❌ **Phase 12**: Phoenix LiveView UI (future work)

**Completion**: 11/12 phases (92%)

See [masterplan.md](masterplan.md) and [masterplan-redeal.md](masterplan-redeal.md) for details.

## License

Copyright © 2025 Pidro Team

## Contributing

See the masterplan documents for implementation details and contribution guidelines.
