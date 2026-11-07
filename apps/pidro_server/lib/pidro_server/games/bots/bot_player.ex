defmodule PidroServer.Games.Bots.BotPlayer do
  @moduledoc """
  GenServer representing a single bot player in a game.

  Subscribes to game PubSub updates, detects when it's the bot's turn,
  and automatically executes legal actions using a configurable strategy.

  ## Features

  - Subscribes to game PubSub updates on start
  - Detects when it's the bot's turn by checking current_turn == position
  - Picks actions via configurable strategy module
  - Applies actions using GameAdapter with configurable delay
  - Can be paused/resumed during gameplay
  """

  use GenServer
  require Logger
  alias PidroServer.Games.Bots.{BotBrain, Strategy}
  alias PidroServer.Games.Bots.Strategies.RulebookStrategy
  alias PidroServer.Games.GameAdapter

  @default_strategy RulebookStrategy

  ## Public API

  @spec start_link(map() | keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec pause(pid()) :: :ok
  def pause(pid) do
    GenServer.cast(pid, :pause)
  end

  @spec resume(pid()) :: :ok
  def resume(pid) do
    GenServer.cast(pid, :resume)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.cast(pid, :stop)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    room_code = Map.fetch!(opts, :room_code)
    position = Map.fetch!(opts, :position)
    strategy = Map.get(opts, :strategy, @default_strategy)
    delay_ms_override = Map.get(opts, :delay_ms)
    paused? = Map.get(opts, :paused?, false)

    bot_user_id = "bot_#{room_code}_#{position}"

    {strategy_module, persona} =
      case PidroServer.Games.RoomManager.join_bot(room_code, bot_user_id, self(), position) do
        {:ok, room, ^position} ->
          Logger.info("Bot #{bot_user_id} joined room #{room_code} at #{position}")
          seat = room.seats[position]
          {seat.bot_strategy || Strategy.resolve(strategy), seat.bot_persona}

        {:ok, _room, other_position} ->
          Logger.warning(
            "Bot #{bot_user_id} requested #{position} but got #{other_position} in room #{room_code}"
          )

          {Strategy.resolve(strategy), nil}

        {:error, reason} ->
          Logger.warning(
            "Bot #{bot_user_id} could not join room #{room_code}: #{inspect(reason)}"
          )

          {Strategy.resolve(strategy), nil}
      end

    tempo_factor = PidroServer.BotCatalogue.tempo_factor(persona)
    :ok = GameAdapter.subscribe(room_code)

    Logger.info(
      "BotPlayer started for room #{room_code}, position #{position}, strategy #{inspect(strategy_module)}, persona #{persona}, tempo factor #{tempo_factor}"
    )

    state = %{
      room_code: room_code,
      position: position,
      user_id: bot_user_id,
      strategy: strategy_module,
      delay_ms_override: delay_ms_override,
      tempo_factor: tempo_factor,
      move_scheduled?: false,
      paused?: paused?
    }

    {:ok, state, {:continue, :check_initial_move}}
  end

  @impl true
  def handle_continue(:check_initial_move, state) do
    case GameAdapter.get_state(state.room_code) do
      {:ok, game_state} ->
        {:noreply, maybe_schedule_move(game_state, state)}

      {:error, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:state_update, room_code, payload}, %{room_code: room_code} = state) do
    case extract_state_update(payload) do
      {:ok, game_state, delay_ms} ->
        {:noreply, maybe_schedule_move(game_state, state, delay_ms)}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:game_over, _room_code, _winner, _scores}, state) do
    Logger.info("BotPlayer for room #{state.room_code}, position #{state.position} - Game over")
    {:noreply, %{state | move_scheduled?: false}}
  end

  @impl true
  def handle_info({:progression_summary, _room_code, _summaries}, state),
    do: {:noreply, state}

  @impl true
  def handle_info({:turn_timer_started, _payload}, state), do: {:noreply, state}

  @impl true
  def handle_info({:turn_timer_cancelled, _payload}, state), do: {:noreply, state}

  @impl true
  def handle_info({:turn_auto_played, _payload}, state), do: {:noreply, state}

  # Ignore disconnect cascade PubSub messages
  @impl true
  def handle_info({:player_reconnected, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:player_disconnected, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:player_reconnecting, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:bot_substitute_active, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:seat_permanently_botted, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:player_reclaimed_seat, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:owner_decision_available, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:owner_changed, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:substitute_available, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:substitute_seat_closed, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:substitute_joined, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:seat_lifecycle, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:readiness_updated, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:invite_redeemed, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:seat_moved, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:kicked, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:seat_invitation_declined, _}, state), do: {:noreply, state}

  # Ignore Phoenix Channel broadcast messages (presence_diff, game_state, etc.).
  # BotPlayer subscribes to the same PubSub topic as GameChannel, so it receives
  # channel-level broadcasts. Game state updates are already handled via the
  # direct {:state_update, room_code, payload} PubSub messages above.
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:make_move, state) do
    BotBrain.execute_move(state, "BotPlayer", &PidroServer.Games.RoomManager.apply_bot_action/4)
    {:noreply, %{state | move_scheduled?: false}}
  end

  @impl true
  def handle_info(:pause, state) do
    {:noreply, %{state | paused?: true}}
  end

  @impl true
  def handle_info(:resume, state) do
    new_state = %{state | paused?: false}

    case GameAdapter.get_state(state.room_code) do
      {:ok, game_state} ->
        {:noreply, maybe_schedule_move(game_state, new_state)}

      {:error, _reason} ->
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(message, state) do
    PidroServer.Games.UnexpectedMessage.report(__MODULE__, message)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("BotPlayer paused for room #{state.room_code}, position #{state.position}")
    {:noreply, %{state | paused?: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("BotPlayer resumed for room #{state.room_code}, position #{state.position}")
    new_state = %{state | paused?: false}

    case GameAdapter.get_state(state.room_code) do
      {:ok, game_state} ->
        {:noreply, maybe_schedule_move(game_state, new_state)}

      {:error, _reason} ->
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast(:stop, state) do
    Logger.info("BotPlayer stopping for room #{state.room_code}, position #{state.position}")
    PidroServer.Games.RoomManager.leave_room(state.user_id)
    GameAdapter.unsubscribe(state.room_code)
    {:stop, :normal, state}
  end

  ## Private Functions

  defp should_make_move?(game_state, state) do
    not state.paused? and BotBrain.should_make_move?(game_state, state.position)
  end

  defp maybe_schedule_move(game_state, state, transition_delay_ms \\ 0) do
    if should_make_move?(game_state, state) do
      opts = Keyword.put(schedule_opts(state), :pace, Map.get(game_state.config, :pace, :quick))
      BotBrain.schedule_move_once(state, transition_delay_ms, opts)
    else
      state
    end
  end

  defp schedule_opts(%{delay_ms_override: nil, tempo_factor: factor}), do: [tempo_factor: factor]

  defp schedule_opts(%{delay_ms_override: delay_ms}) do
    [base_delay_ms: delay_ms, variance_ms: 0, min_delay_ms: delay_ms]
  end

  defp extract_state_update(%{state: game_state, transition_delay_ms: delay_ms})
       when is_map(game_state) and is_integer(delay_ms),
       do: {:ok, game_state, delay_ms}

  defp extract_state_update(%{state: game_state}) when is_map(game_state),
    do: {:ok, game_state, 0}

  defp extract_state_update(game_state) when is_map(game_state), do: {:ok, game_state, 0}
  defp extract_state_update(_payload), do: :error
end
