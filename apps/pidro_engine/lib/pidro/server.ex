defmodule Pidro.Server do
  @moduledoc """
  GenServer wrapper for the Pidro game engine.

  Provides a stateful interface to the pure functional game engine core,
  suitable for Phoenix/LiveView integration via process registry.

  ## Features

  - Wraps pure functional game engine in a GenServer
  - Maintains game state in process state
  - Provides synchronous API for game actions
  - Optional telemetry events for monitoring
  - Supports game history and replay

  ## Usage

      # Start a game server
      {:ok, pid} = Pidro.Server.start_link(game_id: "game_123")

      # Apply an action
      {:ok, state} = Pidro.Server.apply_action(pid, :north, {:bid, 10})

      # Get legal actions
      actions = Pidro.Server.legal_actions(pid, :north)

      # Get current state
      state = Pidro.Server.get_state(pid)

      # Check if game is over
      game_over? = Pidro.Server.game_over?(pid)

  ## Registry Integration

  Games can be registered by ID for lookup:

      # Start with registry
      {:ok, pid} = Pidro.Server.start_link(game_id: "game_123", name: {:via, Registry, {Pidro.Registry, "game_123"}})

      # Look up by game ID
      [{pid, _}] = Registry.lookup(Pidro.Registry, "game_123")

  ## Telemetry Events

  The server emits the following telemetry events (when telemetry is enabled):

  - `[:pidro, :server, :action, :start]` - Before processing an action
  - `[:pidro, :server, :action, :stop]` - After successfully processing an action
  - `[:pidro, :server, :action, :exception]` - When action processing fails
  - `[:pidro, :server, :game, :complete]` - When a game finishes
  - `[:pidro, :server, :redeal, :complete]` - When second_deal phase completes
  - `[:pidro, :server, :kill_rule, :applied]` - When kill rule is applied (cards killed)
  - `[:pidro, :server, :dealer_rob, :complete]` - When dealer robs the pack

  ## State Structure

  The server maintains:
  - `game_state` - The current game state from the engine
  - `game_id` - Optional game identifier
  - `telemetry_enabled?` - Whether to emit telemetry events
  """

  use GenServer

  alias Pidro.Core.Types
  alias Pidro.Core.GameState, as: GS
  alias Pidro.Core.Types.GameState
  alias Pidro.Game.Engine

  # Override default child_spec to use :temporary restart strategy
  # This prevents games from being automatically restarted when they crash
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # Client API

  @doc """
  Starts a game server.

  ## Options

  - `:game_id` - Optional identifier for the game
  - `:name` - Optional registration name (supports {:via, module, term} tuples)
  - `:telemetry` - Whether to emit telemetry events (default: true)
  - `:initial_state` - Optional initial game state (default: new game)
  - `:checkpoint` - Optional bounded `(snapshot, cause) -> :ok | {:error, term}`
    persistence boundary. Failures never reject gameplay unless `:durable` is
    set. The engine retains the initial snapshot and failure counts, not an
    unbounded retry queue.
  - `:durable` - When true, a transition is committed only once its
    checkpoint returns `:ok`: a refused action replies `{:error, :not_saved}`
    and leaves the game as it was, and a refused timed transition is tried
    again a second later. A refused start checkpoint stops the game with
    `:not_saved`. Default false.
  - `:game_instance_id` and `:state_revision` - Resume a saved game under its
    own identity, from `:initial_state`. A resumed game is already archived,
    so it writes no start checkpoint.
  - `:state_observer` - Optional `{module, function}` called synchronously with
    the game ID and state after changes. Keep observers local and bounded;
    no observer is installed by default.
  - `:seed` - Optional seed for the game's chance stream. Omit it and the
    server generates fresh entropy, which is what a live game wants. Supply it
    and the game is reproducible, including across `reset/1`.

  ## Randomness

  This server is the engine's entropy boundary: it is the only production
  expression that generates randomness for a game. The engine itself draws
  exclusively from the chance value carried in `%GameState{}`.

      no :seed, no :initial_state   -> fresh entropy from :crypto
      :seed s                       -> a game reproducible from s
      :initial_state gs             -> gs.chance is preserved exactly

  `reset/1` follows the same rule: a server started with a `:seed` restarts
  into the identical game, an unseeded one into a fresh one.

  ## Examples

      # Start with auto-generated name
      {:ok, pid} = Pidro.Server.start_link()

      # Start with game ID
      {:ok, pid} = Pidro.Server.start_link(game_id: "game_123")

      # Start with registry
      {:ok, pid} = Pidro.Server.start_link(
        game_id: "game_123",
        name: {:via, Registry, {Pidro.Registry, "game_123"}}
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_server_opts)
  end

  @doc """
  Applies an action to the game.

  ## Parameters

  - `server` - The server pid or registered name
  - `position` - The position of the player making the action
  - `action` - The action to perform
  - `timeout` - Maximum wait in milliseconds (defaults to 5000)

  ## Returns

  - `{:ok, new_state}` if successful
  - `{:error, reason}` if the action is invalid

  ## Examples

      {:ok, state} = Pidro.Server.apply_action(pid, :north, {:bid, 10})
      {:ok, state} = Pidro.Server.apply_action(pid, :east, :pass)
  """
  @spec apply_action(GenServer.server(), Types.position(), Types.action()) ::
          {:ok, GameState.t()} | {:error, term()}
  @spec apply_action(GenServer.server(), Types.position(), Types.action(), timeout()) ::
          {:ok, GameState.t()} | {:error, term()}
  def apply_action(server, position, action, timeout \\ 5_000) do
    GenServer.call(server, {:apply_action, position, action}, timeout)
  end

  @doc """
  Applies an action and returns the previous state plus the atomically committed
  server snapshot. This is used by real-time adapters that must publish phase
  timing from the same commit as the game state.
  """
  @spec apply_action_with_snapshot(
          GenServer.server(),
          Types.position(),
          Types.action(),
          timeout()
        ) :: {:ok, GameState.t(), map()} | {:error, term()}
  def apply_action_with_snapshot(server, position, action, timeout \\ 5_000) do
    GenServer.call(server, {:apply_action_with_snapshot, position, action}, timeout)
  end

  @doc """
  Gets the list of legal actions for a position.

  ## Parameters

  - `server` - The server pid or registered name
  - `position` - The position to get legal actions for

  ## Returns

  List of legal actions for the position.

  ## Examples

      actions = Pidro.Server.legal_actions(pid, :north)
      # => [{:bid, 6}, {:bid, 7}, ..., {:bid, 14}, :pass]
  """
  @spec legal_actions(GenServer.server(), Types.position()) :: [Types.action()]
  def legal_actions(server, position) do
    GenServer.call(server, {:legal_actions, position})
  end

  @doc """
  Gets the current game state.

  ## Parameters

  - `server` - The server pid or registered name
  - `timeout` - Maximum wait in milliseconds (defaults to 5000)

  ## Returns

  The current game state.

  ## Examples

      state = Pidro.Server.get_state(pid)
      IO.inspect(state.phase)
  """
  @spec get_state(GenServer.server()) :: GameState.t()
  @spec get_state(GenServer.server(), timeout()) :: GameState.t()
  def get_state(server, timeout \\ 5_000) do
    GenServer.call(server, :get_state, timeout)
  end

  @doc """
  Gets an atomic game-state snapshot with server-owned presentation timing.
  """
  @spec get_snapshot(GenServer.server(), timeout()) :: map()
  def get_snapshot(server, timeout \\ 5_000) do
    GenServer.call(server, :get_snapshot, timeout)
  end

  @doc """
  Sets the room's pace after the caller has authorized its seated human.
  Switching to quick releases a held hand.

      :ok = Pidro.Server.set_pace(pid, :own)
  """
  @spec set_pace(GenServer.server(), :quick | :own) :: :ok | {:error, :not_saved}
  def set_pace(server, pace) when pace in [:quick, :own],
    do: GenServer.call(server, {:set_pace, pace})

  @doc """
  Releases a held hand, or does nothing if no hand is waiting.

      :ok = Pidro.Server.continue_hand(pid)
  """
  @spec continue_hand(GenServer.server()) :: :ok | {:error, :not_saved}
  def continue_hand(server), do: GenServer.call(server, :continue_hand)

  @doc """
  Checks if the game is over.

  ## Parameters

  - `server` - The server pid or registered name

  ## Returns

  `true` if the game is complete, `false` otherwise.

  ## Examples

      if Pidro.Server.game_over?(pid) do
        IO.puts("Game finished!")
      end
  """
  @spec game_over?(GenServer.server()) :: boolean()
  def game_over?(server) do
    GenServer.call(server, :game_over?)
  end

  @doc """
  Gets the winner of the game (if complete).

  ## Parameters

  - `server` - The server pid or registered name

  ## Returns

  - `{:ok, team}` if the game is complete
  - `{:error, :game_not_over}` if the game is still in progress

  ## Examples

      case Pidro.Server.winner(pid) do
        {:ok, team} -> IO.puts("Winner: \#{team}")
        {:error, :game_not_over} -> IO.puts("Game still in progress")
      end
  """
  @spec winner(GenServer.server()) :: {:ok, Types.team()} | {:error, :game_not_over}
  def winner(server) do
    GenServer.call(server, :winner)
  end

  @doc """
  Gets the game history (list of events).

  ## Parameters

  - `server` - The server pid or registered name

  ## Returns

  List of game events in chronological order.

  ## Examples

      events = Pidro.Server.get_history(pid)
      Enum.each(events, &IO.inspect/1)
  """
  @spec get_history(GenServer.server()) :: [Types.event()]
  def get_history(server) do
    GenServer.call(server, :get_history)
  end

  @doc """
  Resets the game to a new state.

  ## Parameters

  - `server` - The server pid or registered name

  ## Returns

  `:ok`

  ## Examples

      :ok = Pidro.Server.reset(pid)
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    game_id = Keyword.get(opts, :game_id)
    telemetry_enabled? = Keyword.get(opts, :telemetry, true)
    seed = Keyword.get(opts, :seed)

    # A supplied state already carries its own chance value; constructing one
    # here is the only place a game's randomness is chosen. `get_lazy/3` keeps
    # `fresh_seed/0` unevaluated when a seed was supplied.
    initial_state =
      case Keyword.fetch(opts, :initial_state) do
        {:ok, game_state} ->
          game_state

        :error ->
          GS.new(
            seed: Keyword.get_lazy(opts, :seed, &fresh_seed/0),
            variant: Keyword.get(opts, :variant, :finnish),
            config: Keyword.get(opts, :config, %{})
          )
      end

    dealer_selection_delay_ms = Keyword.get(opts, :dealer_selection_delay_ms, 3_000)
    deal_transition_delay_ms = Keyword.get(opts, :deal_transition_delay_ms, 0)
    dealer_rob_presentation_ms = Keyword.get(opts, :dealer_rob_presentation_ms, 5_000)
    pubsub = Keyword.get(opts, :pubsub)
    resumed? = Keyword.has_key?(opts, :game_instance_id)

    state =
      %{
        game_state: initial_state,
        game_id: game_id,
        seed: seed,
        telemetry_enabled?: telemetry_enabled?,
        checkpoint: Keyword.get(opts, :checkpoint),
        durable?: Keyword.get(opts, :durable, false),
        checkpoint_event_count: length(initial_state.events),
        checkpoint_initial: nil,
        checkpoint_initial_deal: nil,
        checkpoint_last_cause: nil,
        checkpoint_failures: 0,
        # A resumed game's revision is the one its archive holds.
        checkpoint_last_ack: if(resumed?, do: Keyword.get(opts, :state_revision, 0)),
        checkpoint_status: :healthy,
        checkpoint_users: Keyword.get(opts, :archive_user_ids, []),
        checkpoint_participation_truncated: false,
        dealer_selection_delay_ms: dealer_selection_delay_ms,
        deal_transition_delay_ms: deal_transition_delay_ms,
        pubsub: pubsub,
        state_observer: Keyword.get(opts, :state_observer),
        game_instance_id:
          Keyword.get_lazy(opts, :game_instance_id, fn ->
            Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
          end),
        state_revision: Keyword.get(opts, :state_revision, 0),
        dealer_selection_presentation: nil,
        dealer_selection_timer_ref: nil,
        dealer_selection_token: nil,
        dealer_rob_presentation_ms: dealer_rob_presentation_ms,
        dealer_rob_presentation: nil,
        dealer_rob_timer_ref: nil,
        dealer_rob_token: nil
      }
      |> maybe_schedule_dealer_selection_advance()
      |> then(&if(resumed?, do: &1, else: checkpoint(&1, %{kind: :start})))

    # A durable game that cannot save its start never starts.
    if saved?(state), do: {:ok, observe_state(state)}, else: {:stop, :not_saved}
  end

  @impl true
  def handle_call({:apply_action, position, action}, _from, state) do
    apply_game_action(position, action, :state, state)
  end

  def handle_call({:apply_action_with_snapshot, position, action}, _from, state) do
    apply_game_action(position, action, :snapshot, state)
  end

  @impl true
  def handle_call({:legal_actions, position}, _from, state) do
    actions = Engine.legal_actions(state.game_state, position)
    {:reply, actions, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.game_state, state}
  end

  @impl true
  def handle_call(:get_snapshot, _from, state) do
    {:reply, snapshot(state), state}
  end

  def handle_call({:set_pace, pace}, _from, state) do
    game = %{state.game_state | config: Map.put(state.game_state.config, :pace, pace)}

    new_state =
      %{state | game_state: game, state_revision: state.state_revision + 1}
      |> checkpoint(%{kind: :pace, pace: pace})

    cond do
      not saved?(new_state) ->
        {:reply, {:error, :not_saved}, state}

      pace == :quick and game.phase == :hand_complete ->
        continue_held_hand(new_state)

      true ->
        broadcast_state_change(new_state)
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:continue_hand, _from, %{game_state: %{phase: :hand_complete}} = state),
    do: continue_held_hand(state)

  def handle_call(:continue_hand, _from, state), do: {:reply, :ok, state}

  def handle_call(:archive_close, _from, state) do
    checkpoint(state, %{kind: :closed, last_cause: state.checkpoint_last_cause})
    {:stop, :normal, :ok, state}
  end

  def handle_call(:archive_health, _from, state) do
    health = %{
      status: state.checkpoint_status,
      failures: state.checkpoint_failures,
      last_acknowledged_revision: state.checkpoint_last_ack,
      state_revision: state.state_revision
    }

    {:reply, health, state}
  end

  def handle_call({:archive_participants, users}, _from, state) do
    union = Enum.uniq(state.checkpoint_users ++ users)

    if union == state.checkpoint_users do
      {:reply, :ok, state}
    else
      state = %{
        state
        | checkpoint_users: Enum.take(union, 256),
          checkpoint_participation_truncated:
            state.checkpoint_participation_truncated or length(union) > 256
      }

      {:reply, :ok, persist_checkpoint(state, state.checkpoint_last_cause)}
    end
  end

  @impl true
  def handle_call(:game_over?, _from, state) do
    result = Engine.game_over?(state.game_state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:winner, _from, state) do
    result = Engine.winner(state.game_state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    events = state.game_state.events
    {:reply, events, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    game =
      GS.new(
        seed: reset_seed(state),
        variant: state.game_state.variant,
        config: state.game_state.config
      )

    new_state = replace_game_state(state, game) |> checkpoint(%{kind: :reset})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_state, new_game_state}, _from, state) do
    new_state = replace_game_state(state, new_game_state) |> checkpoint(%{kind: :replace_state})
    {:reply, :ok, new_state}
  end

  defp apply_game_action(position, action, reply_kind, state) do
    %{game_state: game_state, telemetry_enabled?: telemetry?} = state

    if telemetry? do
      emit_telemetry(:start, %{position: position, action: action}, state)
    end

    start_time = System.monotonic_time()

    case Engine.apply_action(game_state, position, action) do
      {:ok, new_game_state} ->
        if telemetry? do
          duration = System.monotonic_time() - start_time

          emit_telemetry(
            :stop,
            %{position: position, action: action, duration: duration},
            state
          )

          # Check if game just completed
          if new_game_state.phase == :complete and game_state.phase != :complete do
            emit_telemetry(:game_complete, %{winner: new_game_state.winner}, state)
          end

          # Emit redeal-specific telemetry events
          emit_redeal_telemetry(game_state, new_game_state, state)
        end

        new_state =
          state
          |> Map.put(:game_state, new_game_state)
          |> Map.update!(:state_revision, &(&1 + 1))
          |> maybe_schedule_dealer_rob_presentation(game_state, new_game_state, action)
          |> maybe_schedule_dealer_selection_advance()
          |> checkpoint(%{kind: :action, position: position, action: action})

        # A refused commit leaves the previous state, whose timer tokens make
        # any timer scheduled above stale.
        cond do
          not saved?(new_state) ->
            {:reply, {:error, :not_saved}, state}

          reply_kind == :state ->
            {:reply, {:ok, new_game_state}, observe_state(new_state)}

          true ->
            {:reply, {:ok, game_state, snapshot(new_state)}, observe_state(new_state)}
        end

      {:error, _reason} = error ->
        if telemetry? do
          duration = System.monotonic_time() - start_time

          emit_telemetry(
            :exception,
            %{position: position, action: action, reason: error, duration: duration},
            state
          )
        end

        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(
        {:advance_from_dealer_selection, token},
        %{dealer_selection_token: token} = state
      )
      when not is_nil(token) do
    %{game_state: game_state} = state

    case Engine.advance_from_dealer_selection(game_state) do
      {:ok, new_game_state} ->
        new_state =
          state
          |> Map.put(:game_state, new_game_state)
          |> Map.update!(:state_revision, &(&1 + 1))
          |> Map.put(:dealer_selection_presentation, nil)
          |> checkpoint(%{kind: :initial_deal})

        if saved?(new_state) do
          new_state = clear_dealer_selection_presentation(new_state)
          # The first hand is dealt: hold the bots while clients deal it out.
          broadcast_state_change(new_state, state.deal_transition_delay_ms)
          {:noreply, new_state}
        else
          {:noreply, retry_later(state, {:advance_from_dealer_selection, token})}
        end

      {:error, _reason} ->
        # Already advanced (e.g., by a concurrent action) — ignore
        {:noreply, clear_dealer_selection_presentation(state)}
    end
  end

  def handle_info({:advance_from_dealer_selection, _stale_token}, state), do: {:noreply, state}

  def handle_info({:clear_dealer_rob_presentation, token}, %{dealer_rob_token: token} = state)
      when not is_nil(token) do
    new_state =
      state
      |> Map.put(:dealer_rob_presentation, nil)
      |> Map.update!(:state_revision, &(&1 + 1))
      |> checkpoint(%{kind: :presentation_cleared})

    if saved?(new_state) do
      new_state = clear_dealer_rob_presentation(new_state)
      broadcast_state_change(new_state)
      {:noreply, new_state}
    else
      {:noreply, retry_later(state, {:clear_dealer_rob_presentation, token})}
    end
  end

  def handle_info({:clear_dealer_rob_presentation, _stale_token}, state), do: {:noreply, state}

  # Private Helpers

  defp continue_held_hand(state) do
    {:ok, game} = Engine.continue_hand(state.game_state)

    new_state =
      %{state | game_state: game, state_revision: state.state_revision + 1}
      |> checkpoint(%{kind: :continue_hand})

    if saved?(new_state) do
      broadcast_state_change(new_state, state.deal_transition_delay_ms)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_saved}, state}
    end
  end

  # Whether a durable game may commit this state: its checkpoint was saved.
  defp saved?(%{durable?: true, checkpoint: checkpoint} = state) when checkpoint != nil,
    do: state.checkpoint_last_ack == state.state_revision

  defp saved?(_state), do: true

  defp retry_later(state, message) do
    Process.send_after(self(), message, 1_000)
    state
  end

  defp checkpoint(%{checkpoint: nil} = state, _cause), do: state

  defp checkpoint(state, cause) do
    events = state.game_state.events
    replaced? = cause.kind in [:reset, :replace_state]
    offset = if replaced?, do: 0, else: state.checkpoint_event_count

    cause =
      Map.merge(cause, %{engine_events: Enum.drop(events, offset), events_replaced: replaced?})

    persist_checkpoint(state, cause)
  end

  defp persist_checkpoint(%{checkpoint: nil} = state, _cause), do: state
  # A resumed game has written nothing yet; its next transition carries the users.
  defp persist_checkpoint(state, nil), do: state

  defp persist_checkpoint(state, cause) do
    current = snapshot(state)
    initial = state.checkpoint_initial || current
    deal = state.checkpoint_initial_deal || if(cause.kind == :initial_deal, do: current)

    metadata =
      Map.merge(cause, %{
        initial_snapshot: initial,
        initial_deal: deal,
        failures: state.checkpoint_failures,
        participant_user_ids: state.checkpoint_users,
        participation_truncated: state.checkpoint_participation_truncated
      })

    state = %{
      state
      | checkpoint_initial: initial,
        checkpoint_initial_deal: deal,
        checkpoint_event_count: length(state.game_state.events),
        checkpoint_last_cause: cause
    }

    case state.checkpoint.(current, metadata) do
      :ok ->
        %{state | checkpoint_last_ack: state.state_revision, checkpoint_status: :healthy}

      {:error, _} ->
        %{
          state
          | checkpoint_failures: state.checkpoint_failures + 1,
            checkpoint_status: :degraded
        }
    end
  end

  defp maybe_schedule_dealer_selection_advance(
         %{
           game_state: %{phase: :dealer_selection, dealer_selection_cuts: cuts},
           dealer_selection_delay_ms: delay_ms
         } = state
       )
       when not is_nil(cuts) do
    # A timer already running is left to fire under its stale token: a
    # transition its commit refuses keeps the state that timer belongs to.
    token = make_ref()
    started_at_ms = System.system_time(:millisecond)
    timer_ref = Process.send_after(self(), {:advance_from_dealer_selection, token}, delay_ms)

    %{
      state
      | dealer_selection_presentation: %{
          started_at_ms: started_at_ms,
          ends_at_ms: started_at_ms + delay_ms
        },
        dealer_selection_timer_ref: timer_ref,
        dealer_selection_token: token
    }
  end

  defp maybe_schedule_dealer_selection_advance(state), do: state

  defp maybe_schedule_dealer_rob_presentation(state, old_game_state, new_game_state, action) do
    new_events = Enum.drop(new_game_state.events, length(old_game_state.events))

    case Enum.find(new_events, &match?({:dealer_robbed_pack, _, _, _}, &1)) do
      {:dealer_robbed_pack, dealer, _, _} ->
        ordinary_discards =
          Enum.flat_map(new_events, fn
            {:cards_discarded, _, cards} -> cards
            _ -> []
          end)

        newly_discarded = new_game_state.discarded_cards -- old_game_state.discarded_cards
        robbed_discards = newly_discarded -- ordinary_discards
        kept = new_game_state.players[dealer].hand
        pool = kept ++ robbed_discards
        delay_ms = state.dealer_rob_presentation_ms
        started_at_ms = System.system_time(:millisecond)
        # As above, a running timer fires under its stale token.
        token = make_ref()

        %{
          state
          | dealer_rob_presentation: %{
              dealer: dealer,
              automatic: not match?({:select_hand, _}, action),
              pool: pool,
              kept: kept,
              discarded: robbed_discards,
              started_at_ms: started_at_ms,
              ends_at_ms: started_at_ms + delay_ms
            },
            dealer_rob_timer_ref:
              Process.send_after(self(), {:clear_dealer_rob_presentation, token}, delay_ms),
            dealer_rob_token: token
        }

      nil ->
        state
    end
  end

  # Optional effect-boundary projection. Standalone engine consumers need no observer.
  defp observe_state(%{state_observer: nil} = state), do: state

  defp observe_state(%{state_observer: {module, function}} = state) do
    apply(module, function, [state.game_id, state.game_state])
    state
  end

  defp broadcast_state_change(state, transition_delay_ms \\ 0) do
    observe_state(state)
    publish_state_change(state, transition_delay_ms)
  end

  defp publish_state_change(%{pubsub: nil}, _transition_delay_ms), do: :ok

  defp publish_state_change(%{pubsub: pubsub, game_id: game_id} = state, transition_delay_ms) do
    apply(Phoenix.PubSub, :broadcast, [
      pubsub,
      "game:#{game_id}",
      {:state_update, game_id,
       Map.put(snapshot(state), :transition_delay_ms, transition_delay_ms)}
    ])
  end

  defp snapshot(state) do
    %{
      game_instance_id: state.game_instance_id,
      state_revision: state.state_revision,
      server_time_ms: System.system_time(:millisecond),
      state: state.game_state,
      presentation: %{
        dealer_selection: state.dealer_selection_presentation,
        dealer_rob: state.dealer_rob_presentation
      }
    }
  end

  # The engine's only source of entropy in the production path. Everything the
  # game draws afterwards is derived from this, deterministically, inside
  # `%GameState{}`.
  #
  # A cryptographic seed makes the starting point unpredictable; it does not
  # turn `:exsss` into a cryptographic generator. This matches the randomness
  # standard the engine had before chance became explicit.
  defp fresh_seed do
    <<a::64, b::64, c::64>> = :crypto.strong_rand_bytes(24)
    {a, b, c}
  end

  # A server started with an explicit seed restarts into the identical game;
  # an unseeded one gets a fresh one, matching what `init/1` did.
  defp reset_seed(%{seed: nil}), do: fresh_seed()
  defp reset_seed(%{seed: seed}), do: seed

  defp replace_game_state(state, game_state) do
    state
    |> clear_dealer_selection_presentation()
    |> clear_dealer_rob_presentation()
    |> Map.put(:game_state, game_state)
    |> Map.update!(:state_revision, &(&1 + 1))
    |> maybe_schedule_dealer_selection_advance()
    |> observe_state()
  end

  defp clear_dealer_selection_presentation(state) do
    if state.dealer_selection_timer_ref do
      Process.cancel_timer(state.dealer_selection_timer_ref)
    end

    %{
      state
      | dealer_selection_presentation: nil,
        dealer_selection_timer_ref: nil,
        dealer_selection_token: nil
    }
  end

  defp clear_dealer_rob_presentation(state) do
    if state.dealer_rob_timer_ref do
      Process.cancel_timer(state.dealer_rob_timer_ref)
    end

    %{
      state
      | dealer_rob_presentation: nil,
        dealer_rob_timer_ref: nil,
        dealer_rob_token: nil
    }
  end

  defp emit_telemetry(event_suffix, measurements, state) do
    metadata = %{
      game_id: state.game_id,
      phase: state.game_state.phase,
      hand_number: state.game_state.hand_number
    }

    # Only emit if telemetry is available
    if Code.ensure_loaded?(:telemetry) do
      apply(:telemetry, :execute, [
        [:pidro, :server, :action, event_suffix],
        measurements,
        metadata
      ])
    end
  end

  defp emit_redeal_telemetry(old_state, new_state, server_state) do
    # Emit event when second_deal phase completes with cards_requested data
    if old_state.phase == :second_deal and new_state.phase == :playing and
         map_size(new_state.cards_requested) > 0 do
      metadata = %{
        game_id: server_state.game_id,
        phase: :second_deal,
        hand_number: new_state.hand_number,
        cards_requested: new_state.cards_requested,
        dealer_pool_size: new_state.dealer_pool_size
      }

      measurements = %{
        total_cards_dealt: Enum.sum(Map.values(new_state.cards_requested))
      }

      if Code.ensure_loaded?(:telemetry) do
        apply(:telemetry, :execute, [
          [:pidro, :server, :redeal, :complete],
          measurements,
          metadata
        ])
      end
    end

    # Emit event when cards are killed (entering playing phase with killed_cards)
    if old_state.phase != :playing and new_state.phase == :playing and
         map_size(new_state.killed_cards) > 0 do
      metadata = %{
        game_id: server_state.game_id,
        phase: :playing,
        hand_number: new_state.hand_number,
        killed_cards_count:
          Enum.map(new_state.killed_cards, fn {pos, cards} -> {pos, length(cards)} end)
          |> Map.new()
      }

      measurements = %{
        total_killed:
          Enum.sum(Enum.map(new_state.killed_cards, fn {_pos, cards} -> length(cards) end))
      }

      if Code.ensure_loaded?(:telemetry) do
        apply(:telemetry, :execute, [
          [:pidro, :server, :kill_rule, :applied],
          measurements,
          metadata
        ])
      end
    end

    # Emit event when dealer robs pack (dealer_pool_size set)
    if is_nil(old_state.dealer_pool_size) and not is_nil(new_state.dealer_pool_size) do
      metadata = %{
        game_id: server_state.game_id,
        phase: new_state.phase,
        hand_number: new_state.hand_number,
        dealer: new_state.current_dealer,
        pool_size: new_state.dealer_pool_size
      }

      measurements = %{
        dealer_pool_size: new_state.dealer_pool_size
      }

      if Code.ensure_loaded?(:telemetry) do
        apply(:telemetry, :execute, [
          [:pidro, :server, :dealer_rob, :complete],
          measurements,
          metadata
        ])
      end
    end
  end
end
