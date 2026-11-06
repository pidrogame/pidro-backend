defmodule PidroServer.Games.Bots.SubstituteBot do
  @moduledoc """
  GenServer that fills in for a disconnected player during a live game.

  Unlike `BotPlayer`, a SubstituteBot does NOT join the room — it takes over
  an existing seat that was vacated by a disconnected human. It subscribes to
  game PubSub updates, detects when it's the bot's turn, and plays moves
  with the room's configured rulebook profile.

  RoomManager starts and monitors these temporary children under BotSupervisor.
  The seat's bot_pid is the sole action authority; only RoomManager replaces it
  after a crash. Reclaim/open/finish terminate the child via
  `DynamicSupervisor.terminate_child/2`, which also stops a bot waiting on an
  action reply from RoomManager without a synchronous-stop deadlock.

  Recovery reads the current engine state and schedules at most one pending
  move. Shared-topic lifecycle notifications do not alter that pending move.
  """

  # RoomManager owns recovery and the authoritative seat PID. An automatic
  # supervisor restart would create an untracked controller.
  use GenServer, restart: :temporary
  require Logger

  alias PidroServer.Games.Bots.{BotBrain, Strategy}
  alias PidroServer.Games.GameAdapter

  ## Public API

  @doc """
  Starts a substitute bot for the given room and position.

  Returns `{:ok, pid}` on success. The bot is started under `BotSupervisor`.
  """
  @spec start(String.t(), atom(), atom()) :: {:ok, pid()} | {:error, term()}
  def start(room_code, position, difficulty \\ :basic) do
    DynamicSupervisor.start_child(
      PidroServer.Games.Bots.BotSupervisor,
      {__MODULE__, room_code: room_code, position: position, difficulty: difficulty}
    )
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    room_code = Keyword.fetch!(opts, :room_code)
    position = Keyword.fetch!(opts, :position)

    :ok = GameAdapter.subscribe(room_code)

    Logger.info("SubstituteBot started for room #{room_code} at #{position}")

    state = %{
      room_code: room_code,
      position: position,
      strategy: Strategy.resolve(Keyword.get(opts, :difficulty, :basic)),
      move_scheduled?: false
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
    Logger.info("SubstituteBot (#{state.room_code}/#{state.position}) - Game over")
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

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:make_move, state) do
    BotBrain.execute_move(
      state,
      "SubstituteBot",
      &PidroServer.Games.RoomManager.apply_substitute_action/4
    )

    {:noreply, %{state | move_scheduled?: false}}
  end

  # Ignore disconnect cascade PubSub messages
  @impl true
  def handle_info({:player_reconnecting, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:bot_substitute_active, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:seat_permanently_botted, _}, state), do: {:noreply, state}
  @impl true
  def handle_info({:player_reconnected, _}, state), do: {:noreply, state}
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
  def handle_info({tag, _}, state)
      when tag in [:invite_redeemed, :seat_moved, :kicked, :seat_invitation_declined],
      do: {:noreply, state}

  # This is a shared topic, not a private bot protocol.
  @impl true
  def handle_info(message, state) do
    PidroServer.Games.UnexpectedMessage.report(__MODULE__, message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    GameAdapter.unsubscribe(state.room_code)

    Logger.info("SubstituteBot stopped for room #{state.room_code} at #{state.position}")

    :ok
  end

  defp maybe_schedule_move(game_state, state, transition_delay_ms \\ 0) do
    if BotBrain.should_make_move?(game_state, state.position) do
      BotBrain.schedule_move_once(state, transition_delay_ms,
        pace: Map.get(game_state.config, :pace, :quick)
      )
    else
      state
    end
  end

  defp extract_state_update(%{state: game_state, transition_delay_ms: delay_ms})
       when is_map(game_state) and is_integer(delay_ms),
       do: {:ok, game_state, delay_ms}

  defp extract_state_update(%{state: game_state}) when is_map(game_state),
    do: {:ok, game_state, 0}

  defp extract_state_update(game_state) when is_map(game_state), do: {:ok, game_state, 0}
  defp extract_state_update(_payload), do: :error
end
