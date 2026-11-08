# Pidro Engine - Development Guide

Quick reference for building, testing, and understanding the Finnish Pidro game engine.

---

## IMPORTANT

- **NEVER modify game specs/rules** - they live in separate documentation
- **NEVER delete test files** or fixture data
- This file defines HOW to build and validate, not WHAT to build
- All code must pass validation before claiming completion

---

## Quick Validation Loop

**Required policy:** read [`docs/testing.md`](../../docs/testing.md) and root
`AGENTS.md`. Feature orbs prove changed behavior plus a control, then run only
affected test files/lines. No full suites, full gameplay/account/visual regression
or native checks in feature orbs. One standard phone size for app proof; a second
only for a named layout risk. Full/native coverage is deliberate release work on
Marcel's machine or a release runner. List it as pending; browser proof is not native
proof. Missing focused evidence blocks completion. Do not foreground-watch/poll CI.
This policy supersedes older blanket quality/coverage command examples below.

```bash
# Feature work: choose the actual affected file/line, show behavior + control
mix test test/unit/game/bidding_completion_test.exs
mix format --check-formatted
# Full mix precommit / mix test / coverage / Dialyzer sweeps: release/manual only
```

---

## Project Setup

This is an Elixir umbrella app. The engine is located at:
```
apps/pidro_engine/
```

### Dependencies
```bash
mix deps.get
```

### Compilation
```bash
mix compile
```

---

## Core Development Commands

### Testing & Validation

```bash
# Full release/manual command (NOT the feature-orb workflow)
mix test                                    # Full regression, deliberate release only
mix test --failed                           # Re-run only failed tests
mix test --stale                            # May run everything on a cold cache; not an orb shortcut
mix test test/path/to/test.exs             # Test specific file
mix test test/path/to/test.exs:42          # Test specific line

# Specific test types
mix test test/unit/                         # Unit tests only
mix test test/properties/                   # Property tests only

# Coverage tracking
mix coveralls                               # Generate coverage report
mix coveralls.html                          # HTML report → cover/excoveralls.html
mix test --cover                            # Quick coverage

# Type checking (catches bugs before runtime)
mix dialyzer                                # First run slow, then fast
mix dialyzer --format dialyxir             # Pretty output

# Code quality
mix credo --strict                          # Linting
mix format                                  # Auto-format code
mix format --check-formatted                # Check without changing
mix quality                                 # Runs: format + dialyzer + credo

# Documentation
mix docs                                    # Generate ExDoc
```

### Fast Development Workflow

```bash
# Strict compilation
mix compile --warnings-as-errors

# Interactive development
iex -S mix                                  # Start with project loaded
recompile()                                 # In iex: recompile after changes

# Continuous feedback
mix test.watch                              # Auto-run tests (if installed)
```

---

## Key Finnish Pidro Rules (The Gotchas)

### The Wrong 5 Rule
The most important rule that differs from other Pidro variants:
- When a suit is declared trump, BOTH the Right 5 and Wrong 5 are trump cards
- **Right 5**: The 5 of the trump suit (worth 5 points)
- **Wrong 5**: The 5 of the SAME COLOR suit (also worth 5 points)

Examples:
- If Hearts is trump → 5 of Diamonds is also trump (hearts and diamonds are both red)
- If Clubs is trump → 5 of Spades is also trump (clubs and spades are both black)

### Trump Ranking Order
From highest to lowest:
```
A > K > Q > J > 10 > 9 > 8 > 7 > 6 > Right5 > Wrong5 > 4 > 3 > 2
```

Key point: Right 5 beats Wrong 5, but both rank BELOW the 6 of trump.

### Point Distribution
Total points per suit: **14 points**
- Ace: 1 point
- Jack: 1 point
- 10: 1 point
- Right 5: 5 points
- Wrong 5: 5 points
- 2: 1 point
- All others: 0 points

### The 2 of Trump Rule
When a player wins a trick containing the 2 of trump, they keep 1 point for themselves (not their team). This is the only card that scores individually.

---

## Project Structure

```
lib/pidro/
├── core/                    # Core data structures (Phase 0-1)
│   ├── types.ex            # Type definitions and helper functions
│   ├── card.ex             # Card operations (trump logic, ranking)
│   ├── deck.ex             # The 52 cards in a fixed generation order
│   ├── player.ex           # Player state
│   ├── trick.ex            # Trick-taking logic
│   └── gamestate.ex        # Game state container
├── game/                    # Game logic (Phase 2-7)
│   ├── engine.ex           # Main game engine API
│   ├── state_machine.ex    # Phase transitions
│   ├── bidding.ex          # Bidding logic
│   ├── dealing.ex          # Card dealing and dealer selection
│   ├── trump.ex            # Trump declaration and utilities
│   ├── discard.ex          # Discard and second deal
│   ├── play.ex             # Trick-taking gameplay
│   └── errors.ex           # Error handling and formatting
├── finnish/                 # Finnish variant specifics (Phase 7)
│   ├── rules.ex            # Finnish rule validation
│   └── scorer.ex           # Finnish scoring rules
├── iex.ex                   # IEx interactive helpers (Phase 10)
└── pidro_engine.ex          # Public API module

test/
├── unit/                    # Unit tests for modules
├── properties/              # Property-based tests
└── support/
    └── generators.ex        # StreamData generators
```

---

## Development Workflow

### Current Status
Phases 0-7 and 10 are complete:
- Project scaffold with all dependencies
- Core types (Card, Deck, Player, Trick, GameState)
- State machine and game engine API
- Bidding, trump declaration, discarding
- Trick-taking gameplay and scoring
- IEx interactive helpers for testing
- Full game is playable in IEx console

### Remaining Work
- Phase 8: Event sourcing and notation (optional)
- Phase 9: Performance optimizations (optional)
- Phase 11: OTP/GenServer wrapper (future)

### Development Cycle
1. Read the phase requirements in `_masterplan.md`
2. Implement the module with `@spec` for all public functions
3. Write unit tests in `test/unit/`
4. Write property tests in `test/properties/`
5. Run affected test files/lines and show the changed engine output plus a control
6. Compile/type-check affected code as relevant; full Dialyzer is release coverage
7. Format/lint changed code; no blanket full-suite precommit in feature orbs
8. Update `_masterplan.md` to mark phase complete

### Bug Fixing Cycle (Make Dave Thomas Proud)

**ALWAYS follow this order when fixing bugs:**

1. **Reproduce the bug with a failing test FIRST**
   - Write a test that demonstrates the bug
   - Watch it fail (RED)
   - Commit the failing test with a clear description
   
2. **Fix the bug**
   - Implement the fix
   - Watch the test pass (GREEN)
   
3. **Refactor if needed**
   - Clean up the code
   - Ensure tests still pass
   
4. **Validate**
   - Run affected tests and exercise the changed contract plus a control
   - Compile/format/lint as relevant
   - List full engine/game/account/native regression as release work, not orb work

**Never fix a bug without a test that proves it exists.**

Example workflow:
```bash
# 1. Write failing test
mix test test/unit/game/bidding_completion_test.exs
# Commit: "test(bidding): reproduce premature phase transition bug"

# 2. Fix the code
# Commit: "fix(bidding): require 3 consecutive passes after last bid"

# 3. Validate
mix test test/unit/game/bidding_completion_test.exs
# Show old/new state and a nearby control; full regression stays at release
```

---

## Code Style & Elixir Idioms

### Pattern Matching Over Conditionals

```elixir
# ✅ GOOD: Pattern match in function heads
def process(%State{status: :ready} = state, data) when is_binary(data) do
  {:ok, do_process(state, data)}
end

def process(%State{status: status}, _data) do
  {:error, "Cannot process in #{status} state"}
end

# ❌ BAD: Using if/case unnecessarily
def process(state, data) do
  if state.status == :ready do
    if is_binary(data) do
      {:ok, do_process(state, data)}
    end
  end
end
```

### Tagged Tuples for Return Values

```elixir
# ✅ GOOD: Always use tagged tuples for public APIs
{:ok, result}                               # Success
{:error, reason}                            # Clear error
{:error, :invalid_input, "Details"}        # Detailed error

# For private functions that can't fail
defp transform(data), do: String.upcase(data)

# ❌ BAD: Raising for domain logic (only for programmer errors)
def risky() do
  raise "Something went wrong"  # Don't do this!
end
```

### with for Complex Operations

```elixir
# ✅ GOOD: Chain validations cleanly
def complex_operation(input) do
  with {:ok, validated} <- validate(input),
       {:ok, processed} <- process(validated),
       {:ok, result} <- finalize(processed) do
    {:ok, result}
  end
end

# ❌ BAD: Nested case statements
def complex_operation(input) do
  case validate(input) do
    {:ok, validated} ->
      case process(validated) do
        {:ok, processed} ->
          finalize(processed)
      end
  end
end
```

### Module Organization

```elixir
defmodule MyApp.Feature do
  @moduledoc """
  One-line description of module purpose.

  Longer explanation with usage examples and context.
  """

  # Public API at top
  @doc """
  Brief description.

  ## Parameters
  - `param` - Description

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  ## Examples

      iex> MyApp.Feature.do_thing("input")
      {:ok, "output"}
  """
  @spec do_thing(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def do_thing(param) do
    # Implementation
  end

  # Private functions at bottom
  defp helper(data), do: transform(data)
end
```

---

## Documentation Requirements

**Every public function MUST have:**

```elixir
@doc """
Brief description of function purpose.

## Parameters
- `param_name` - What it represents

## Returns
- Success case
- Error cases

## Examples

    iex> ModuleName.function_name(arg)
    expected_result
"""
@spec function_name(type()) :: return_type()
def function_name(param) do
  # implementation
end
```

**Every module MUST have:**

- `@moduledoc` explaining purpose
- `@type` definitions for custom types
- `@spec` for all public functions

---

## Testing Strategy

### Write Tests First (TDD)

```elixir
# 1. Write failing test (RED)
test "descriptive test name" do
  assert MyModule.function(input) == expected
end

# 2. Implement to make it pass (GREEN)
# 3. Refactor if needed
# 4. Ensure all tests still pass
```

### Test Structure

```elixir
defmodule MyApp.FeatureTest do
  use ExUnit.Case, async: true

  alias MyApp.Feature

  describe "function_name/1" do
    test "handles valid input" do
      assert {:ok, result} = Feature.function_name("valid")
      assert result == expected
    end

    test "rejects invalid input" do
      assert {:error, _reason} = Feature.function_name("invalid")
    end
  end

  describe "edge_cases" do
    setup do
      # Common setup for this group
      {:ok, state: initial_state()}
    end

    test "handles edge case", %{state: state} do
      # Test using setup data
    end
  end
end
```

### Test Categories

```elixir
# Unit tests: Fast, many, isolated
test "pure function logic"

# Integration tests: Slower, fewer, realistic
@tag :integration
test "full workflow from start to finish"

# Property tests: Invariants that should always hold
@tag :property
property "invariant always holds" do
  check all input <- generator() do
    assert invariant(process(input))
  end
end
```

### Property-Based Testing

This project uses StreamData for property-based testing to prove correctness mathematically.

Key properties tested:
- Deck always contains exactly 52 cards
- Wrong 5 is always trump when same-color suit is trump
- Trump ranking is transitive and consistent
- Card comparison is transitive
- Point values always sum to 14 per suit

### Writing Generators

Custom generators are in `test/support/generators.ex`:
```elixir
# Example: Generate valid cards
card_generator =
  StreamData.tuple({
    StreamData.integer(2..14),  # rank
    StreamData.member_of([:hearts, :diamonds, :clubs, :spades])  # suit
  })
```

---

## LLM Validation Protocol

### Before Starting Work

```bash
# 1. Inspect baseline, reproduce the changed scenario (not the full suite)
git status                                  # Check working directory

# 2. Understand the task
# - Read TODO/issue description
# - Check related documentation
# - Review existing tests for context
```

### While Implementing

```bash
# Follow TDD cycle
mix test test/path/to_new_test.exs         # Watch it fail (RED)
# Implement feature
mix test test/path/to_new_test.exs         # Watch it pass (GREEN)
mix format                                  # Format
```

### After Implementing

```bash
# Focused feature validation (choose actual affected test paths)
mix format                                  # Format changed files only
mix compile --warnings-as-errors            # No warnings
mix test test/path/to_new_test.exs           # Affected tests, not all tests
# Show direct behavior/control evidence; full precommit/Dialyzer/coverage at release

# If ALL pass:
git add .
git commit -m "type: description"

# If ANY fail: FIX before proceeding
```

### Self-Validation Checklist

Before claiming work is complete:

- [ ] Affected tests pass; changed behavior and control are observed
- [ ] Full regression/native checks explicitly deferred to release owner
- [ ] Relevant compile/lint checks pass
- [ ] `mix format --check-formatted` passes
- [ ] Release owner has the full coverage/regression checks listed as pending
- [ ] All public functions have `@spec` and `@doc`
- [ ] Tests cover success AND error cases
- [ ] Returns use tagged tuples `{:ok, _}` or `{:error, _}`
- [ ] No compiler warnings
- [ ] Documentation matches implementation

---

## Common Mistakes to Avoid

### ❌ Forgetting to Handle All Cases

```elixir
# BAD: Missing pattern match
def process(%State{ready: true} = state) do
  {:ok, do_work(state)}
end
# What if ready: false? Crash!

# GOOD: Explicit handling
def process(%State{ready: true} = state) do
  {:ok, do_work(state)}
end

def process(%State{ready: false}) do
  {:error, "State not ready"}
end
```

### ❌ Attempting Mutation

```elixir
# BAD: Elixir data is immutable
def update(state) do
  state.counter = state.counter + 1  # Won't work!
  state
end

# GOOD: Return new structure
def update(state) do
  %{state | counter: state.counter + 1}
end
```

### ❌ Missing Type Specs

```elixir
# BAD: No type information
def process(data) do
  # implementation
end

# GOOD: Clear types
@spec process(String.t()) :: {:ok, integer()} | {:error, atom()}
def process(data) do
  # implementation
end
```

### ❌ Not Using with for Error Handling

```elixir
# BAD: Nested pattern matching
case step1(input) do
  {:ok, result1} ->
    case step2(result1) do
      {:ok, result2} ->
        step3(result2)
      error -> error
    end
  error -> error
end

# GOOD: Clean with statement
with {:ok, result1} <- step1(input),
     {:ok, result2} <- step2(result1),
     {:ok, result3} <- step3(result2) do
  {:ok, result3}
end
```

---

## Type Specifications

### Define Custom Types

```elixir
@type result :: {:ok, term()} | {:error, atom()}
@type status :: :pending | :processing | :complete | :failed
@type id :: String.t()

# Use in specs
@spec process(id(), map()) :: result()
def process(id, data) do
  # implementation
end
```

### Common Type Patterns

```elixir
# Basic types
@type string_result :: {:ok, String.t()} | {:error, atom()}
@type list_of_ids :: [String.t()]
@type optional_value :: term() | nil

# Struct types
@type t :: %__MODULE__{
  field1: String.t(),
  field2: integer(),
  field3: atom()
}

# Union types
@type response :: success_response() | error_response()
@type success_response :: {:ok, result :: term()}
@type error_response :: {:error, reason :: atom() | String.t()}
```

---

## Debugging Techniques

### In IEx

```elixir
# Start with project loaded
iex -S mix

# Inspect values
some_value |> IO.inspect(label: "Debug")

# Recompile after changes
recompile()

# Get function documentation
h MyModule.function_name

# See function specs
s MyModule.function_name

# View source
open MyModule

# Reload a module
r Pidro.Core.Card
r Pidro.Game.Engine
```

### Test Debugging

```bash
# Run with detailed output
mix test --trace

# Run single test
mix test test/path/to/test.exs:42

# See full error details
mix test --trace --seed 0 --max-failures 1
```

### Finding Issues

```bash
# Check for unused dependencies
mix deps.unlock --check-unused

# Check for unused aliases/imports
mix compile --warnings-as-errors

# Detailed dialyzer output
mix dialyzer --format dialyxir

# Find code smells
mix credo --strict --all
```

---

## IEx Interactive Development

### Start IEx with Project Loaded
```bash
iex -S mix
```

### Playing a Game Interactively

```elixir
# Import IEx helpers
import Pidro.IEx

# Start a new game (dealer selected, cards dealt)
state = new_game()

# View the game state with pretty formatting
pretty_print(state)

# Check legal actions for a player
show_legal_actions(state, :north)

# Apply an action (returns {:ok, new_state} or {:error, reason})
{:ok, state} = step(state, :north, {:bid, 10})

# Continue playing...
show_legal_actions(state, :east)
{:ok, state} = step(state, :east, :pass)

# Run a full demo game
demo_game()
```

### Low-Level Testing Commands

```elixir
# Create a card
card = Pidro.Core.Card.new(14, :hearts)

# Check if card is trump
Pidro.Core.Card.is_trump?(card, :hearts)

# Shuffle a deck from an explicit chance value (the engine draws from
# `state.chance`; there is no process-RNG deck constructor). A deck is just a
# list of cards.
{deck, _chance} = Pidro.Core.Chance.shuffle(Pidro.Core.Deck.ordered(), Pidro.Core.Chance.from_seed(1))

# Deal cards off the top
{cards, remaining_deck} = Enum.split(deck, 9)

# Create a player
player = Pidro.Core.Player.new(:north, :north_south)

# Add cards to player's hand
player = Pidro.Core.Player.add_cards(player, cards)

# Use the engine directly. `new/1` requires a seed: it is the game's chance
# stream, and there is no default. Live games get theirs from `Pidro.Server`.
alias Pidro.Game.Engine
state = Pidro.Core.GameState.new(seed: 1)
{:ok, state} = Pidro.Game.Dealing.select_dealer(state)
{:ok, state} = Engine.apply_action(state, :north, {:bid, 10})
```

---

## Common Issues & Solutions

### Issue: Dialyzer Warnings
**Solution**: Ensure all public functions have `@spec` declarations. Check return types match specs.

### Issue: Wrong 5 Not Treated as Trump
**Solution**: Use `Pidro.Core.Card.is_trump?/2` which handles the same-color logic. Don't manually check suit equality.

### Issue: Property Tests Fail Intermittently
**Solution**: Check generators are producing valid data. Property tests run 100 times by default.

### Issue: Compilation Errors After Adding Module
**Solution**: Check that aliases and type imports are correct. Ensure parent modules exist.

---

## Performance Considerations

### Benchmark Critical Paths

```elixir
# In test file
@tag :benchmark
test "operation performance" do
  {time_microseconds, result} = :timer.tc(fn ->
    MyModule.expensive_operation(input)
  end)

  assert time_microseconds < 1_000_000  # Less than 1 second
end
```

### Profile Memory Usage

```bash
# In iex
:observer.start()  # GUI profiler

# Or programmatically
{time, memory} = :timer.tc(fn ->
  result = MyModule.operation()
  {:erlang.memory(), result}
end)
```

### Performance Notes

The engine is designed with performance in mind for future optimizations:
- Binary encoding for game state (planned Phase 9)
- ETS caching for legal moves (planned Phase 9)
- Immutable data structures (efficient copying with structure sharing)
- Pure functions (enables parallelization)

Current focus: Correctness first, performance later.

---

## Working with Dependencies

### Adding Dependencies

```elixir
# In mix.exs
defp deps do
  [
    {:dependency_name, "~> 1.0"},
    {:dev_dependency, "~> 2.0", only: [:dev, :test], runtime: false}
  ]
end
```

```bash
# Install new dependencies
mix deps.get

# Update all dependencies
mix deps.update --all

# Check for outdated deps
mix hex.outdated
```

---

## Continuous Integration

### Release/manual validation example (do not install as an orb pre-commit hook)

```bash
#!/bin/sh
# .git/hooks/pre-commit

mix format --check-formatted || exit 1
mix credo --strict || exit 1
mix test || exit 1
mix dialyzer || exit 1

echo "✅ All checks passed"
```

### Full release CI example (not push CI)

```yaml
# Example for GitHub Actions
- name: Run tests
  run: mix test

- name: Check formatting
  run: mix format --check-formatted

- name: Run Credo
  run: mix credo --strict

- name: Run Dialyzer
  run: mix dialyzer

- name: Coverage
  run: mix coveralls.json
```

---

## Commits and PRs

- Use Conventional Commits: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`
- Format: `type(scope): subject`
  - Subject: imperative, lowercase, ≤ 72 chars, no trailing period
  - Scope: concise area, e.g. `engine`, `server`, `web`, `docs`, `ci`, `deps`
- Body (optional): explain why and what (not how). Wrap at ~72 chars. Reference issues with `Refs #123` or `Closes #123`.
- Breaking changes: use `type!` or add a `BREAKING CHANGE:` paragraph in the body
- No emojis. No fluff. Keep precise and factual

Examples:

```text
feat(engine): add trick-taking scoring for rounds
fix(server): handle nil player_id in join
docs(readme): clarify setup for dev DB
refactor(web): extract lobby list component
perf(engine)!: replace naive sort with counting sort
```

Shipping is trunk-based (root `AGENTS.md`), not PR-based. Push affected checks +
smoke, report the CI URL/current status without foreground waits. Full Backend CI
and protected production Deploy are deliberate manual release actions. Show focused
proof and list release gaps; a green check alone never proves changed behavior.

---

## Full release quality gates (not feature-orb checks)

**Before a deliberate release, not before every feature push:**

```bash
# All these exit with 0
mix format --check-formatted  # Code formatted
mix compile --warnings-as-errors  # No warnings
mix test  # All tests pass
mix credo --strict  # No code issues
mix dialyzer  # No type errors
mix coveralls  # Coverage maintained/improved
```

**If any fail, release verification is incomplete.** Feature handoff instead requires
the focused behavior/control proof and affected tests in `docs/testing.md`.

---

## Ralph Methodology Integration

### TODO-Driven Development

```elixir
# In code, use structured TODOs:
# TODO: [PRIORITY] Brief description
# Context: Why needed
# Acceptance: How to validate done
# Refs: Related docs/issues

# Example:
# TODO: [HIGH] Add input validation
# Context: Currently accepts any input
# Acceptance: test/validation_test.exs passes
# Refs: See docs/validation_spec.md
```

### Spec-Driven Implementation

1. **Read the spec** - Check documentation
2. **Write the test** - Encode spec as test
3. **Implement** - Make test pass
4. **Validate** - Run quality checks
5. **Document** - Update `@doc` and commit

---

## Architecture Principles

### Pure Functional Core
- All game logic is pure functions
- No side effects in `core/`, `game/` or `finnish/` — no clock, no process
  dictionary, no ETS, no config reads
- Randomness is an explicit input: every draw comes from `GameState.chance`
  via `Pidro.Core.Chance`, never from the calling process's `:rand`
- Deterministic behavior, stated with its qualifiers: *the same complete
  authoritative state and action, on the same engine version and the OTP
  version pinned in `.tool-versions`, produce equal next state and domain
  events, independently of the caller's RNG state*
- `Pidro.Server` is the effectful boundary and the only production expression
  that generates entropy (`fresh_seed/0`)
- Guarded by `test/unit/core/chance_containment_test.exs` (nothing else in the
  domain reaches `:rand`) and `test/unit/core/chance_vector_test.exs` (one
  seed's exact output, so drift is a loud failure)

### Immutable State
- Game state never mutates
- All operations return new state
- `%GameState{}` is plain data and carries its chance stream, so it
  round-trips through `:erlang.term_to_binary/1` and resumes in another process

### Event Sourcing
- Every action produces an event
- Bids, plays, tricks and scores can be rebuilt from the event history; the
  deck order, the dealer cuts and the chance stream are in no event, so a
  replayed state is not one a game continues from — see
  `guides/event_sourcing.md`

### Separation of Concerns
- Core logic (lib/pidro/core/) - data structures only
- Game logic (lib/pidro/game/) - rules and gameplay
- Variant-specific (lib/pidro/finnish/) - Finnish rules
- Delivery (future) - GenServer wrapper for Phoenix

---

## Resources

- **Game Spec**: `specs/pidro_complete_specification.md` - Complete rules and API
- **Properties**: `specs/game_properties.md` - All testable properties
- **Master Plan**: `_masterplan.md` - Implementation roadmap and status
- **Original Rules**: Ask the oracle (user) for Finnish-specific rule clarifications

---

## Quick Reference: Game Testing Commands

```bash
# Run all tests
mix test

# Run IEx to play a game
iex -S mix

# In IEx:
import Pidro.IEx
state = new_game()
pretty_print(state)
show_legal_actions(state, :north)
{:ok, state} = step(state, :north, {:bid, 10})

# Run a demo game
demo_game()
```

---

## Project Setup

### mix.exs Configuration

```elixir
def project do
  [
    app: :your_app,
    version: "0.1.0",
    elixir: "~> 1.14",
    start_permanent: Mix.env() == :prod,
    aliases: aliases(),
    deps: deps(),

    # Testing
    test_coverage: [tool: ExCoveralls],
    preferred_cli_env: [
      coveralls: :test,
      "coveralls.html": :test
    ],

    # Dialyzer
    dialyzer: [
      plt_add_apps: [:ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  ]
end

defp deps do
  [
    # Quality tools
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
    {:ex_doc, "~> 0.31", only: :dev, runtime: false},
    {:excoveralls, "~> 0.18", only: :test}
  ]
end

defp aliases do
  [
    quality: [
      "format --check-formatted",
      "dialyzer",
      "credo --strict"
    ]
  ]
end
```

**The Golden Rule**: Prove the changed behavior and a control, run affected checks,
and disclose unverified claims. Missing focused proof means verification incomplete;
full/native regression is release work, not a feature-orb obligation.

---

**Last Updated**: 2025-11-01
**Current Phase**: Phases 0-7, 10 Complete
**Status**: Full game playable in IEx
**Version**: 0.1.0
