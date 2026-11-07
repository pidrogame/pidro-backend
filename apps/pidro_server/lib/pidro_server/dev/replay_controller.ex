defmodule PidroServer.Dev.ReplayController do
  @moduledoc """
  Controls hand replay functionality for the development UI.

  Allows scrubbing through a game's event history by reconstructing state
  at any point in time using Pidro.Game.Replay.

  ## Features

  - Jump to any event in history
  - Step forward/backward through events
  - Auto-replay with configurable speed
  - Reconstruct state at any point using event sourcing

  ## Usage

      # Get state at event index 10
      {:ok, state} = ReplayController.get_state_at_event(room_code, 10)

      # Step forward one event
      {:ok, state} = ReplayController.step_forward(room_code, current_index)

      # Step backward one event
      {:ok, state} = ReplayController.step_backward(room_code, current_index)
  """

  alias Pidro.Game.Replay
  alias PidroServer.Games.GameAdapter

  @typedoc "A captured immutable game snapshot, or a room code for legacy callers."
  @type source :: map() | String.t()

  @doc """
  Gets the total number of events for a game.

  Returns the count of events in the engine's event history.
  """
  @spec get_event_count(source()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def get_event_count(room_code) do
    case source_state(room_code) do
      {:ok, state} ->
        count = Replay.history_length(state)
        {:ok, count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the game state at a specific event index.

  Reconstructs state by replaying events from index 0 to the specified index.

  ## Parameters

  - `room_code` - The game room code
  - `event_index` - Zero-based index into event history (0 = after first event)

  ## Examples

      {:ok, state} = ReplayController.get_state_at_event("ABC123", 5)
  """
  @spec get_state_at_event(source(), non_neg_integer()) ::
          {:ok, map()} | {:error, :not_found | :invalid_index}
  def get_state_at_event(room_code, event_index) do
    case source_state(room_code) do
      {:ok, current_state} ->
        total_events = Replay.history_length(current_state)

        cond do
          event_index < 0 ->
            {:error, :invalid_index}

          event_index >= total_events ->
            {:error, :invalid_index}

          event_index == total_events - 1 ->
            # Preserve the exact captured state at its final event.
            {:ok, current_state}

          true ->
            # Replay up to event_index
            events_to_replay = Enum.take(current_state.events, event_index + 1)

            Replay.replay(events_to_replay)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Steps forward one event from the current index.

  ## Parameters

  - `room_code` - The game room code
  - `current_index` - Current event index

  ## Returns

  - `{:ok, new_state, new_index}` - The state and index after stepping forward
  - `{:error, :at_end}` - Already at the last event
  - `{:error, reason}` - Other errors
  """
  @spec step_forward(source(), non_neg_integer()) ::
          {:ok, map(), non_neg_integer()} | {:error, atom()}
  def step_forward(room_code, current_index) do
    case get_event_count(room_code) do
      {:ok, total_events} ->
        next_index = current_index + 1

        if next_index >= total_events do
          {:error, :at_end}
        else
          case get_state_at_event(room_code, next_index) do
            {:ok, state} ->
              {:ok, state, next_index}

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Steps backward one event from the current index.

  ## Parameters

  - `room_code` - The game room code
  - `current_index` - Current event index

  ## Returns

  - `{:ok, new_state, new_index}` - The state and index after stepping backward
  - `{:error, :at_start}` - Already at the first event
  - `{:error, reason}` - Other errors
  """
  @spec step_backward(source(), non_neg_integer()) ::
          {:ok, map(), non_neg_integer()} | {:error, atom()}
  def step_backward(room_code, current_index) do
    if current_index <= 0 do
      {:error, :at_start}
    else
      prev_index = current_index - 1

      case get_state_at_event(room_code, prev_index) do
        {:ok, state} ->
          {:ok, state, prev_index}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Gets information about an event at a specific index.

  ## Returns

  A map with event details:
  - `:type` - Event type atom
  - `:player` - Player position (if applicable)
  - `:description` - Human-readable description
  """
  @spec get_event_info(source(), non_neg_integer()) ::
          {:ok, map()} | {:error, :not_found | :invalid_index}
  def get_event_info(room_code, event_index) do
    case source_state(room_code) do
      {:ok, current_state} ->
        total_events = Replay.history_length(current_state)

        if event_index >= 0 && event_index < total_events do
          event = Enum.at(current_state.events, event_index)

          {:ok,
           %{
             type: event_type(event),
             player: event_player(event),
             description: format_event(event)
           }}
        else
          {:error, :invalid_index}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Jumps to a specific phase in the game.

  Finds the first event of the specified phase and returns that state.

  ## Parameters

  - `room_code` - The game room code
  - `phase` - Phase to jump to (`:bidding`, `:playing`, etc.)

  ## Returns

  - `{:ok, state, event_index}` - State at the start of that phase
  - `{:error, :phase_not_found}` - Phase hasn't occurred yet
  """
  @spec jump_to_phase(source(), atom()) ::
          {:ok, map(), non_neg_integer()} | {:error, atom()}
  def jump_to_phase(room_code, target_phase) do
    case source_state(room_code) do
      {:ok, current_state} ->
        # Find the first event where phase matches target
        case find_phase_start(current_state.events, target_phase) do
          {:ok, index} ->
            case get_state_at_event(room_code, index) do
              {:ok, state} ->
                {:ok, state, index}

              {:error, reason} ->
                {:error, reason}
            end

          :not_found ->
            {:error, :phase_not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private Functions

  defp source_state(%{events: events} = state) when is_list(events), do: {:ok, state}
  defp source_state(room_code) when is_binary(room_code), do: GameAdapter.get_state(room_code)
  defp source_state(_), do: {:error, :not_found}

  defp event_type({type, _player, _first, _second}), do: type
  defp event_type({type, _player, _data}), do: type
  defp event_type({type, _data}), do: type
  defp event_type(type) when is_atom(type), do: type

  defp event_player({_type, player, _first, _second}) when is_atom(player), do: player
  defp event_player({_type, player, _data}) when is_atom(player), do: player
  defp event_player({_type, player}) when is_atom(player), do: player
  defp event_player(_), do: nil

  defp format_event({:dealer_selected, player, _card}) do
    "#{format_position(player)} selected as dealer"
  end

  defp format_event({:cards_dealt, _hands}) do
    "Cards dealt to all players"
  end

  defp format_event({:bid_made, player, amount}) do
    "#{format_position(player)} bid #{amount}"
  end

  defp format_event({:player_passed, player}) do
    "#{format_position(player)} passed"
  end

  defp format_event({:bidding_complete, player, amount}) do
    "Bidding complete: #{format_position(player)} won with #{amount}"
  end

  defp format_event({:trump_declared, suit}) do
    "Trump declared: #{format_suit(suit)}"
  end

  defp format_event({:cards_discarded, player, cards}) do
    "#{format_position(player)} discarded #{length(cards)} cards"
  end

  defp format_event({:second_deal_complete, _counts}) do
    "Second deal completed"
  end

  defp format_event({:dealer_robbed_pack, player, _requested, _received}) do
    "#{format_position(player)} robbed the pack"
  end

  defp format_event({:cards_killed, killed_map}) do
    total = killed_map |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    "#{total} cards killed"
  end

  defp format_event({:card_played, player, {rank, suit}}) do
    "#{format_position(player)} played #{format_rank(rank)}#{format_suit(suit)}"
  end

  defp format_event({:trick_won, player, points}) do
    "#{format_position(player)} won trick (#{points} points)"
  end

  defp format_event({:player_went_cold, player, _cards}) do
    "#{format_position(player)} went cold"
  end

  defp format_event({:hand_settled, player, cards}) do
    "#{format_position(player)} laid down #{length(cards)} trumps"
  end

  defp format_event({:hand_scored, team, points}) do
    "Hand scored: #{format_team(team)} earned #{points} points"
  end

  defp format_event({:game_won, team, score}) do
    "Game won by #{format_team(team)} with #{score} points"
  end

  defp format_event(_event), do: "Unknown event"

  defp format_position(pos) do
    pos |> to_string() |> String.capitalize()
  end

  defp format_team(:north_south), do: "North/South"
  defp format_team(:east_west), do: "East/West"
  defp format_team(team), do: inspect(team)

  defp format_suit(:hearts), do: "♥"
  defp format_suit(:diamonds), do: "♦"
  defp format_suit(:clubs), do: "♣"
  defp format_suit(:spades), do: "♠"
  defp format_suit(suit), do: inspect(suit)

  defp format_rank(14), do: "A"
  defp format_rank(13), do: "K"
  defp format_rank(12), do: "Q"
  defp format_rank(11), do: "J"
  defp format_rank(n), do: to_string(n)

  # Find the index of the first event in a given phase
  defp find_phase_start(events, target_phase) do
    # Replay events and track when we enter target phase
    # Only the phase of this state is read, and it is compared against states
    # produced by `Replay.replay/1`, which folds onto the same fixed
    # placeholder seed. See the caveat on `Pidro.Game.Replay.replay/1`.
    initial_state = Pidro.Core.GameState.new(seed: 0)

    events
    |> Enum.with_index()
    |> Enum.reduce_while({initial_state, :not_found}, fn {_event, index}, {state, _} ->
      {:ok, new_state} = Replay.replay(Enum.take(events, index + 1))

      if new_state.phase == target_phase && state.phase != target_phase do
        {:halt, {new_state, {:ok, index}}}
      else
        {:cont, {new_state, :not_found}}
      end
    end)
    |> elem(1)
  end
end
