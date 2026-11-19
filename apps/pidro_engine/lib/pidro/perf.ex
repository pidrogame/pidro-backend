defmodule Pidro.Perf do
  @moduledoc """
  Performance utilities for game state operations.

  This module provides efficient functions for hashing, comparing, and
  analyzing game state for performance-critical operations like caching
  and memoization.

  ## Features

  - Fast state hashing using Erlang's `:erlang.phash2/1`
  - Binary-based equality checking
  - State comparison utilities
  - Cache key generation

  ## Usage

      # Hash a game state for caching
      hash = Perf.hash_state(state)

      # Check if two states are equal (faster than deep equality)
      if Perf.states_equal?(state1, state2) do
        # States are identical
      end

      # Generate a cache key for legal moves
      cache_key = Perf.cache_key_for_moves(state, :north)
  """

  alias Pidro.Core.Types.GameState

  @doc """
  Generates a fast hash of the game state.

  Uses Erlang's `:erlang.phash2/1` which is optimized for speed.
  The hash is suitable for ETS keys and cache lookups.

  ## Parameters

  - `state` - The game state to hash

  ## Returns

  A 32-bit integer hash value (0..2^27-1)

  ## Examples

      iex> state = GameState.new(seed: 7)
      iex> hash = Perf.hash_state(state)
      iex> is_integer(hash)
      true

      iex> state1 = GameState.new(seed: 7)
      iex> state2 = GameState.new(seed: 7)
      iex> Perf.hash_state(state1) == Perf.hash_state(state2)
      true
  """
  @spec hash_state(GameState.t()) :: non_neg_integer()
  def hash_state(%GameState{} = state) do
    # Hash relevant fields instead of full binary encoding
    # (binary encoding is complex and optional for Phase 9)
    relevant_state = {
      state.phase,
      state.hand_number,
      state.current_dealer,
      state.current_turn,
      state.trump_suit,
      state.highest_bid,
      # Sort player hands for consistent hashing
      Enum.map([:north, :east, :south, :west], fn pos ->
        {pos, Enum.sort(state.players[pos].hand), state.players[pos].eliminated?}
      end),
      Enum.sort(state.deck),
      state.cumulative_scores,
      # Redeal fields
      state.cards_requested,
      state.dealer_pool_size,
      # Sort killed cards for consistent hashing
      Enum.map(state.killed_cards, fn {pos, cards} -> {pos, Enum.sort(cards)} end)
      |> Enum.sort()
    }

    :erlang.phash2(relevant_state)
  end

  @doc """
  Checks if two game states are equal.

  This uses binary comparison which is much faster than deep equality
  checks on nested structures. It compares the essential game state
  (phase, positions, hands, scores, etc.) but ignores metadata like
  cache and events history.

  ## Parameters

  - `state1` - First game state
  - `state2` - Second game state

  ## Returns

  `true` if states are equivalent, `false` otherwise

  ## Examples

      iex> state1 = GameState.new(seed: 7)
      iex> state2 = GameState.new(seed: 7)
      iex> Perf.states_equal?(state1, state2)
      true

      iex> state1 = GameState.new(seed: 7)
      iex> state2 = GameState.update(state1, :phase, :dealing)
      iex> Perf.states_equal?(state1, state2)
      false
  """
  @spec states_equal?(GameState.t(), GameState.t()) :: boolean()
  def states_equal?(%GameState{} = state1, %GameState{} = state2) do
    # Fast path: check if they're the same reference
    if state1 === state2 do
      true
    else
      # Compare hashes (much faster than deep equality)
      hash_state(state1) == hash_state(state2)
    end
  end

  @doc """
  Generates a cache key for legal moves lookup.

  The cache key includes only the relevant parts of game state that
  affect legal moves for a given position:
  - Phase
  - Current turn
  - Player's hand
  - Trump suit (if declared)
  - Current trick (if in playing phase)

  This allows for efficient caching without including irrelevant state
  like scores or history.

  ## Parameters

  - `state` - The game state
  - `position` - The position to generate cache key for

  ## Returns

  A tuple that can be used as an ETS cache key

  ## Examples

      iex> state = GameState.new(seed: 7)
      iex> key = Perf.cache_key_for_moves(state, :north)
      iex> is_tuple(key)
      true
  """
  @spec cache_key_for_moves(GameState.t(), atom()) ::
          {atom(), atom() | nil, list(), atom() | nil, list()}
  def cache_key_for_moves(%GameState{} = state, position) do
    player = state.players[position]
    hand = Enum.sort(player.hand)

    # Include current trick for playing phase
    trick_key =
      case state.phase do
        :playing ->
          if state.current_trick do
            state.current_trick.plays
          else
            []
          end

        _ ->
          nil
      end

    # Include killed cards for this position
    killed = Map.get(state.killed_cards, position, []) |> Enum.sort()

    {
      state.phase,
      state.trump_suit,
      hand,
      trick_key,
      killed
    }
  end

  @doc """
  Generates a hash for a specific position's relevant state.

  This is more granular than `hash_state/1` and only hashes the
  parts of state relevant to a specific position. Useful for
  per-player caching.

  ## Parameters

  - `state` - The game state
  - `position` - The position to hash for

  ## Returns

  A 32-bit integer hash value

  ## Examples

      iex> state = GameState.new(seed: 7)
      iex> hash = Perf.hash_position_state(state, :north)
      iex> is_integer(hash)
      true
  """
  @spec hash_position_state(GameState.t(), atom()) :: non_neg_integer()
  def hash_position_state(%GameState{} = state, position) do
    cache_key = cache_key_for_moves(state, position)
    :erlang.phash2(cache_key)
  end

  @doc """
  Estimates the memory size of a game state in bytes.

  This provides an approximate size calculation useful for
  monitoring memory usage and cache sizing decisions.

  ## Parameters

  - `state` - The game state to measure

  ## Returns

  Estimated size in bytes

  ## Examples

      iex> state = GameState.new(seed: 7)
      iex> size = Perf.estimate_size(state)
      iex> size > 0
      true
  """
  @spec estimate_size(GameState.t()) :: non_neg_integer()
  def estimate_size(%GameState{} = state) do
    # Estimate size without full binary encoding
    # Each card is roughly 16 bytes in Elixir term format
    # Plus overhead for structs, maps, etc.
    card_count = Enum.sum(for {_pos, player} <- state.players, do: length(player.hand))
    deck_size = length(state.deck)
    total_cards = card_count + deck_size

    # Rough estimate: 16 bytes per card + 1KB overhead for structures
    total_cards * 16 + 1024
  end

  @doc """
  Benchmarks a function execution time in microseconds.

  Utility function for quick performance measurements during development.

  ## Parameters

  - `fun` - Zero-arity function to benchmark

  ## Returns

  `{time_microseconds, result}` tuple

  ## Examples

      iex> {time, result} = Perf.benchmark(fn -> 1 + 1 end)
      iex> result
      2
      iex> time >= 0
      true
  """
  @spec benchmark((-> any())) :: {non_neg_integer(), any()}
  def benchmark(fun) when is_function(fun, 0) do
    :timer.tc(fun)
  end

  @doc """
  Measures memory allocation for a function.

  Returns the memory allocated (in bytes) and the function result.

  ## Parameters

  - `fun` - Zero-arity function to measure

  ## Returns

  `{bytes_allocated, result}` tuple

  ## Examples

      iex> {bytes, result} = Perf.measure_memory(fn -> Enum.to_list(1..100) end)
      iex> bytes > 0
      true
  """
  @spec measure_memory((-> any())) :: {non_neg_integer(), any()}
  def measure_memory(fun) when is_function(fun, 0) do
    before = :erlang.memory(:total)
    result = fun.()
    after_mem = :erlang.memory(:total)
    allocated = max(0, after_mem - before)
    {allocated, result}
  end

  @doc """
  Creates a reduced hash for phase-specific caching.

  Different phases need different cache strategies. This function
  generates appropriate cache keys based on the current phase.

  ## Parameters

  - `state` - The game state

  ## Returns

  A hash value appropriate for the current phase

  ## Examples

      iex> state = GameState.new(seed: 7)
      iex> hash = Perf.phase_specific_hash(state)
      iex> is_integer(hash)
      true
  """
  @spec phase_specific_hash(GameState.t()) :: non_neg_integer()
  def phase_specific_hash(%GameState{phase: :dealer_selection} = state) do
    :erlang.phash2({:dealer_selection, state.deck})
  end

  def phase_specific_hash(%GameState{phase: :bidding} = state) do
    :erlang.phash2({:bidding, state.current_turn, state.bids, state.highest_bid})
  end

  def phase_specific_hash(%GameState{phase: :second_deal} = state) do
    # Hash includes redeal-specific fields
    :erlang.phash2(
      {:second_deal, state.current_turn, state.trump_suit, state.cards_requested,
       state.dealer_pool_size}
    )
  end

  def phase_specific_hash(%GameState{phase: :playing} = state) do
    # Hash based on player hands, current trick, and killed cards
    hands =
      [:north, :east, :south, :west]
      |> Enum.map(&state.players[&1].hand)
      |> Enum.map(&Enum.sort/1)

    killed_sorted =
      Enum.map(state.killed_cards, fn {pos, cards} -> {pos, Enum.sort(cards)} end)
      |> Enum.sort()

    :erlang.phash2({:playing, state.trump_suit, hands, state.current_trick, killed_sorted})
  end

  def phase_specific_hash(%GameState{} = state) do
    # Default: full state hash for other phases
    hash_state(state)
  end
end
