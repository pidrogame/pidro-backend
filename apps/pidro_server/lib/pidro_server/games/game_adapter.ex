defmodule PidroServer.Games.GameAdapter do
  @moduledoc """
  Adapter for interacting with Pidro.Server game processes.

  Provides convenience functions for:
  - Applying game actions (bid, declare trump, play card)
  - Retrieving game state (full or player-specific)
  - Getting legal actions for a position
  - PubSub subscription management
  - State update broadcasting

  This module acts as a bridge between the Phoenix web layer and the
  Pidro.Server game engine processes.

  ## Usage

      # Apply an action
      {:ok, _state} = GameAdapter.apply_action("A3F9", :north, {:bid, 8})

      # Get game state
      {:ok, state} = GameAdapter.get_state("A3F9")

      # Get state for a specific player
      {:ok, state} = GameAdapter.get_state("A3F9", :north)

      # Subscribe to game updates
      :ok = GameAdapter.subscribe("A3F9")

  ## PubSub Topics

  - `game:<room_code>` - Game-specific updates (state_update, game_over)
  """

  require Logger
  alias Pidro.Game.{Play, Replay}
  alias PidroServer.Diagnostics
  alias PidroServer.Games.{GameRegistry, GameSupervisor, Lifecycle}

  @doc """
  Applies an action to a game.

  Forwards the action to the Pidro.Server process and broadcasts the resulting
  state update to all subscribed clients.

  ## Parameters

    - `room_code` - The room code (e.g., "A3F9")
    - `position` - The player position (`:north`, `:east`, `:south`, `:west`)
    - `action` - The action to apply (e.g., `{:bid, 8}`, `:pass`, `{:play_card, {14, :spades}}`)
    - `timeout` - Maximum wait per engine call in milliseconds (defaults to 5000)

  ## Returns

    - `{:ok, new_state}` on success
    - `{:error, :not_found}` if the game doesn't exist
    - `{:error, :game_unavailable}` if the game stopped or stalled during the call
    - `{:error, reason}` for invalid actions

  ## Examples

      # Bid
      GameAdapter.apply_action("A3F9", :north, {:bid, 8})

      # Pass
      GameAdapter.apply_action("A3F9", :east, :pass)

      # Declare trump
      GameAdapter.apply_action("A3F9", :south, {:declare_trump, :hearts})

      # Play card
      GameAdapter.apply_action("A3F9", :west, {:play_card, {14, :spades}})
  """
  @spec apply_action(String.t(), atom(), term()) :: {:ok, term()} | {:error, term()}
  @spec apply_action(String.t(), atom(), term(), timeout()) :: {:ok, term()} | {:error, term()}
  def apply_action(room_code, position, action, timeout \\ 5_000, diagnostics \\ %{}) do
    started = System.monotonic_time(:millisecond)

    with {:ok, pid} <- GameRegistry.lookup(room_code) do
      try do
        action_key =
          case diagnostics do
            %{user_id: user, action_id: id} when is_binary(id) -> {user, id}
            _ -> nil
          end

        case Pidro.Server.apply_action_with_snapshot(pid, position, action, timeout, action_key) do
          {:replayed, outcome} ->
            {:replayed, outcome}

          # The one info line per applied move. A move the server plays (a
          # bot's, a timed-out turn) has a `seat` and no `user_id`.
          {:ok, old_state, snapshot} ->
            fields =
              %{action: action_name(action)}
              |> Map.merge(diagnostics)
              |> Map.merge(Map.take(snapshot, [:game_instance_id, :state_revision]))
              |> Map.merge(%{
                room_code: room_code,
                seat: position,
                outcome: :accepted,
                duration_ms: System.monotonic_time(:millisecond) - started
              })

            Diagnostics.emit(:action_applied, fields)
            broadcast_state_update(room_code, old_state, snapshot, fields)
            {:ok, snapshot.state}

          # The move could not be saved, so it was not made; the player may retry.
          {:error, :not_saved} ->
            {:error, :game_unavailable}

          {:error, _reason} = error ->
            error
        end
      rescue
        e ->
          Diagnostics.emit(
            :game_process_failed,
            Map.merge(diagnostics, %{room_code: room_code, reason: :exception}),
            :error
          )

          {:error, Exception.message(e)}
      catch
        :exit, reason -> game_exit(room_code, reason, :game_unavailable, diagnostics)
      end
    end
  end

  @doc """
  Gets the current game state.

  Retrieves the full game state from the Pidro.Server process. This includes
  all public information about the game.

  ## Parameters

    - `room_code` - The room code

  ## Returns

    - `{:ok, state}` on success
    - `{:error, :not_found}` if the game doesn't exist

  ## Examples

      iex> GameAdapter.get_state("A3F9")
      {:ok, %{phase: :bidding, current_player: :north, ...}}
  """
  @spec get_state(String.t()) :: {:ok, term()} | {:error, :not_found}
  def get_state(room_code) do
    call_game(room_code, &Pidro.Server.get_state/1)
  end

  @doc """
  Gets the state for a specific player position.

  Returns the full game state (Pidro.Server does not have position-specific views yet).

  ## Parameters

    - `room_code` - The room code
    - `_position` - The player position (currently unused, for future API compatibility)

  ## Returns

    - `{:ok, state}` on success
    - `{:error, :not_found}` if the game doesn't exist

  ## Examples

      iex> GameAdapter.get_state("A3F9", :north)
      {:ok, %{phase: :bidding, ...}}
  """
  @spec get_state(String.t(), atom()) :: {:ok, term()} | {:error, :not_found}
  def get_state(room_code, _position) do
    # The engine returns one authoritative state for every position.
    get_state(room_code)
  end

  @doc """
  Gets the authoritative state and server-owned presentation timing atomically.
  """
  @spec get_snapshot(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_snapshot(room_code) do
    call_game(room_code, &Pidro.Server.get_snapshot/1)
  end

  @doc "Updates an authorized room's pace and broadcasts its current state."
  @spec set_pace(String.t(), :quick | :own) ::
          {:ok, :ok | {:error, :not_saved}} | {:error, term()}
  def set_pace(room_code, pace), do: call_game(room_code, &Pidro.Server.set_pace(&1, pace))

  @doc "Continues a held hand after room authorization."
  @spec continue_hand(String.t()) :: {:ok, :ok | {:error, :not_saved}} | {:error, term()}
  def continue_hand(room_code), do: call_game(room_code, &Pidro.Server.continue_hand/1)

  @doc """
  Gets legal actions for a player position.

  Returns the list of valid actions that the specified player can take in
  the current game state.

  ## Parameters

    - `room_code` - The room code
    - `position` - The player position

  ## Returns

    - `{:ok, actions}` on success
    - `{:error, :not_found}` if the game doesn't exist

  ## Examples

      iex> GameAdapter.get_legal_actions("A3F9", :north)
      {:ok, [{:bid, 6}, {:bid, 7}, ..., :pass]}
  """
  @spec get_legal_actions(String.t(), atom()) :: {:ok, list()} | {:error, :not_found}
  def get_legal_actions(room_code, position) do
    call_game(room_code, &Pidro.Server.legal_actions(&1, position))
  end

  @doc """
  Subscribes to game updates for a room.

  Subscribes the calling process to receive game update messages via PubSub.
  Messages are broadcast on the topic `game:<room_code>`.

  ## Message Types

    - `{:state_update, room_code, %{state: new_state, transition_delay_ms: delay_ms}}` - Game state changed
    - `{:game_over, room_code, winner, scores}` - Game ended

  ## Parameters

    - `room_code` - The room code to subscribe to

  ## Returns

    - `:ok`

  ## Examples

      iex> GameAdapter.subscribe("A3F9")
      :ok
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(room_code) do
    Phoenix.PubSub.subscribe(PidroServer.PubSub, "game:#{room_code}")
  end

  @doc """
  Unsubscribes from game updates for a room.

  Removes the subscription for the calling process from the game's PubSub topic.

  ## Parameters

    - `room_code` - The room code to unsubscribe from

  ## Returns

    - `:ok`

  ## Examples

      iex> GameAdapter.unsubscribe("A3F9")
      :ok
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(room_code) do
    Phoenix.PubSub.unsubscribe(PidroServer.PubSub, "game:#{room_code}")
  end

  @doc """
  Gets the PID for a game process.

  Looks up the game process in the registry. Useful for debugging or
  advanced use cases.

  ## Parameters

    - `room_code` - The room code

  ## Returns

    - `{:ok, pid}` if the game exists
    - `{:error, :not_found}` if no game is registered

  ## Examples

      iex> GameAdapter.get_game("A3F9")
      {:ok, #PID<0.234.0>}
  """
  @spec get_game(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_game(room_code) do
    GameSupervisor.get_game(room_code)
  end

  @doc """
  Undoes the last action in the game.

  Reverts the game state to before the last action was applied. This uses
  the Pidro.Game.Replay.undo/1 function to replay all events except the last one.

  ## Parameters

    - `room_code` - The room code

  ## Returns

    - `{:ok, previous_state}` on success
    - `{:error, :not_found}` if the game doesn't exist
    - `{:error, :no_history}` if there are no actions to undo

  ## Examples

      iex> GameAdapter.undo("A3F9")
      {:ok, %{phase: :bidding, ...}}
  """
  @spec undo(String.t()) :: {:ok, term()} | {:error, term()}
  def undo(room_code) do
    with {:ok, pid} <- GameRegistry.lookup(room_code) do
      try do
        # Get current state
        current_state = Pidro.Server.get_state(pid)

        # Call Replay.undo/1
        case Replay.undo(current_state) do
          {:ok, previous_state} ->
            # Set the game state to the previous state
            # We need to call GenServer.call directly since there's no set_state function
            case GenServer.call(pid, {:set_state, previous_state}) do
              :ok ->
                # Broadcast the state update
                snapshot = Pidro.Server.get_snapshot(pid)
                broadcast_state_update(room_code, current_state, snapshot)
                {:ok, previous_state}

              error ->
                error
            end

          {:error, _reason} = error ->
            error
        end
      rescue
        e ->
          Logger.error(
            "Error undoing action for game #{room_code}: #{Exception.message(e)}\n#{Exception.format_stacktrace()}"
          )

          {:error, Exception.message(e)}
      catch
        :exit, reason -> game_exit(room_code, reason, :not_found)
      end
    end
  end

  ## Private Functions

  defp action_name(action) when is_tuple(action), do: elem(action, 0)
  defp action_name(action), do: action

  # The registry can still name a game that has stopped, and a stopped or
  # stalled game exits whoever calls it. Answer as if the game were gone so the
  # exit costs only this room, not the caller (often the RoomManager).
  defp call_game(room_code, fun) do
    with {:ok, pid} <- GameRegistry.lookup(room_code) do
      try do
        {:ok, fun.(pid)}
      catch
        :exit, reason -> game_exit(room_code, reason, :not_found)
      end
    end
  end

  # Logs only the exit's kind: the full reason can carry the call's arguments.
  defp game_exit(room_code, reason, error, diagnostics \\ %{}) do
    kind =
      case reason do
        {kind, {GenServer, :call, _}} when is_atom(kind) -> kind
        _ -> :crashed
      end

    Diagnostics.emit(
      :game_process_failed,
      Map.merge(diagnostics, %{room_code: room_code, reason: kind}),
      :warning
    )

    {:error, error}
  end

  @doc false
  @spec broadcast_state_update(String.t(), map(), map()) :: :ok | {:error, term()}
  defp broadcast_state_update(
         room_code,
         old_state,
         %{state: new_state} = snapshot,
         diagnostics \\ %{}
       ) do
    try do
      payload =
        Map.put(snapshot, :transition_delay_ms, transition_delay_ms(old_state, new_state))

      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "game:#{room_code}",
        {:state_update, room_code, payload}
      )

      Diagnostics.emit(
        :state_broadcast,
        Map.merge(
          diagnostics,
          Map.merge(
            Map.take(snapshot, [:game_instance_id, :state_revision]),
            %{room_code: room_code}
          )
        ),
        :debug
      )

      # The engine finishes at :complete; older callers may still use :game_over.
      if Map.get(new_state, :phase) in [:complete, :game_over] do
        broadcast_game_over(room_code, new_state)
      end

      :ok
    rescue
      e ->
        Diagnostics.emit(
          :state_broadcast_failed,
          Map.merge(diagnostics, %{room_code: room_code}),
          :error
        )

        {:error, Exception.message(e)}
    end
  end

  @doc false
  @spec broadcast_game_over(String.t(), map()) :: :ok | {:error, term()}
  defp broadcast_game_over(room_code, state) do
    winner = Map.get(state, :winner)
    scores = Map.get(state, :scores) || Map.get(state, :cumulative_scores)

    Phoenix.PubSub.broadcast(
      PidroServer.PubSub,
      "game:#{room_code}",
      {:game_over, room_code, winner, scores}
    )
  end

  @doc false
  @spec transition_delay_ms(map(), map()) :: non_neg_integer()
  def transition_delay_ms(old_state, new_state) do
    cond do
      Map.get(new_state, :phase) == :complete ->
        0

      # The hand's result, then the next hand's deal.
      hand_completed?(old_state, new_state) ->
        Lifecycle.config(:hand_transition_delay_ms) + Lifecycle.config(:deal_transition_delay_ms)

      second_deal_completed?(old_state, new_state) ->
        Lifecycle.config(:second_deal_transition_delay_ms)

      trick_completed?(old_state, new_state) and match?(%{config: %{pace: :own}}, new_state) ->
        Lifecycle.config(:own_trick_transition_delay_ms)

      trick_completed?(old_state, new_state) and Play.settled_play(old_state) != nil ->
        Lifecycle.config(:sweep_trick_delay_ms)

      trick_completed?(old_state, new_state) ->
        Lifecycle.config(:trick_transition_delay_ms)

      true ->
        0
    end
  end

  @spec trick_completed?(map(), map()) :: boolean()
  defp trick_completed?(old_state, new_state) do
    length(Map.get(new_state, :tricks, [])) > length(Map.get(old_state, :tricks, [])) and
      is_nil(Map.get(new_state, :current_trick))
  end

  # Trump named, and the discard, the second deal and the dealer's pick done
  # in one go: the table shows them before anyone plays.
  @spec second_deal_completed?(map(), map()) :: boolean()
  defp second_deal_completed?(old_state, new_state) do
    Map.get(old_state, :phase) == :declaring and Map.get(new_state, :phase) == :playing
  end

  @spec hand_completed?(map(), map()) :: boolean()
  defp hand_completed?(old_state, new_state) do
    Map.get(new_state, :hand_number, 0) > Map.get(old_state, :hand_number, 0)
  end
end
