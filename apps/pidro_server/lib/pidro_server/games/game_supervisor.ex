defmodule PidroServer.Games.GameSupervisor do
  @moduledoc """
  DynamicSupervisor for game processes.

  Manages the lifecycle of individual Pidro.Server game processes. Each game
  runs as an isolated, supervised process that can crash without affecting
  other games or the server itself.

  ## Supervision Strategy

  Uses `:one_for_one` strategy with `:temporary` restart policy for child
  processes. When a game crashes, it is not automatically restarted (games
  are ephemeral and can be recreated if needed).

  ## Usage

      # Start a game
      {:ok, pid} = GameSupervisor.start_game("A3F9")

      # Get a running game
      {:ok, pid} = GameSupervisor.get_game("A3F9")

      # Stop a game
      :ok = GameSupervisor.stop_game("A3F9")
  """

  use DynamicSupervisor

  require Logger
  alias PidroServer.Games.GameRegistry

  @doc """
  Starts the GameSupervisor.

  This supervisor is typically started by PidroServer.Games.Supervisor as part
  of the application supervision tree.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new game process for the given room code.

  The game process is registered in the GameRegistry using the room code,
  allowing other parts of the system to find and communicate with it.

  ## Parameters

    - `room_code` - Unique room code (e.g., "A3F9")
    - `opts` - For a room's game: `:fence`, the room's `{owner, epoch}` in
      `live_rooms`, makes every checkpoint a fenced commit the game waits
      for. A resumed game also passes `:initial_state`, `:game_instance_id`
      and `:state_revision` from `GameArchive.resume/3`.

  ## Returns

    - `{:ok, pid}` on successful start
    - `{:error, {:already_started, pid}}` if a game already exists for this code
    - `{:error, reason}` for other failures

  ## Examples

      iex> GameSupervisor.start_game("A3F9")
      {:ok, #PID<0.234.0>}

      iex> GameSupervisor.start_game("A3F9")
      {:error, {:already_started, #PID<0.234.0>}}
  """
  @spec start_game(room_code :: String.t()) :: DynamicSupervisor.on_start_child()
  @spec start_game(String.t(), :finnish | :louisiana) :: DynamicSupervisor.on_start_child()
  @spec start_game(String.t(), :finnish | :louisiana, :quick | :own) ::
          DynamicSupervisor.on_start_child()
  @spec start_game(String.t(), :finnish | :louisiana, :quick | :own, map()) ::
          DynamicSupervisor.on_start_child()
  @spec start_game(String.t(), :finnish | :louisiana, :quick | :own, map(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_game(room_code, rule_set \\ :finnish, pace \\ :quick, participants \\ %{}, opts \\ []) do
    Logger.info("Starting game for room #{room_code}")

    alias PidroServer.Games.Lifecycle
    fence = Keyword.get(opts, :fence)

    game_opts = [
      name: GameRegistry.via(room_code),
      game_id: room_code,
      variant: rule_set,
      config: %{pace: pace},
      pubsub: PidroServer.PubSub,
      archive_user_ids:
        for({_pos, %{occupant_type: :human, user_id: id}} <- participants, do: id),
      checkpoint:
        if Application.get_env(:pidro_server, :game_archive_enabled, true) do
          fn snapshot, cause -> checkpoint(room_code, participants, snapshot, cause, fence) end
        end,
      durable: fence != nil,
      state_observer: {PidroServer.Games.AdminGameSummary, :record},
      dealer_selection_delay_ms: Lifecycle.config(:dealer_selection_delay_ms),
      deal_transition_delay_ms: Lifecycle.config(:deal_transition_delay_ms)
    ]

    game_opts =
      game_opts ++ Keyword.take(opts, [:initial_state, :game_instance_id, :state_revision])

    # Start Pidro.Server under this supervisor
    child_spec = %{
      id: Pidro.Server,
      start: {Pidro.Server, :start_link, [game_opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} = result ->
        Logger.info("Game started successfully for room #{room_code}, PID: #{inspect(pid)}")
        result

      {:error, {:already_started, pid}} = error ->
        Logger.warning("Game already exists for room #{room_code}, PID: #{inspect(pid)}")
        error

      {:error, reason} = error ->
        Logger.error("Failed to start game for room #{room_code}: #{inspect(reason)}")
        error
    end
  end

  defp checkpoint(room_code, participants, snapshot, cause, nil),
    do: PidroServer.GameArchive.capture(room_code, participants, snapshot, cause)

  # A fenced write means another node owns the room now: the room manager
  # gives the room up here.
  defp checkpoint(room_code, participants, snapshot, cause, {_owner, epoch} = fence) do
    with {:error, :fenced} = refused <-
           PidroServer.GameArchive.commit(room_code, participants, snapshot, cause, fence) do
      send(PidroServer.Games.RoomManager, {:room_fenced, room_code, epoch})
      refused
    end
  end

  @doc """
  Stops the game process for the given room code.

  Terminates the game process gracefully. The process will be removed from
  the supervision tree and the registry.

  ## Parameters

    - `room_code` - The room code of the game to stop

  ## Returns

    - `:ok` on successful termination
    - `{:error, :game_not_found}` if no game exists for that code
    - `{:error, :not_found}` if the process cannot be terminated

  ## Examples

      iex> GameSupervisor.stop_game("A3F9")
      :ok

      iex> GameSupervisor.stop_game("INVALID")
      {:error, :game_not_found}
  """
  @spec stop_game(room_code :: String.t()) ::
          :ok | {:error, :game_not_found} | {:error, :not_found}
  def stop_game(room_code) do
    case GameRegistry.lookup(room_code) do
      {:ok, pid} ->
        Logger.info("Stopping game for room #{room_code}")

        case close_game(pid) do
          :ok ->
            Logger.info("Game stopped successfully for room #{room_code}")
            :ok

          {:error, :not_found} = error ->
            Logger.warning("Game process not found in supervisor for room #{room_code}")
            error
        end

      {:error, :not_found} ->
        Logger.warning("No game found for room #{room_code}")
        {:error, :game_not_found}
    end
  end

  defp close_game(pid) do
    GenServer.call(pid, :archive_close)
  catch
    :exit, _ ->
      # A failed closure write must not hold a room open. The last checkpoint
      # remains active until reconciliation labels the missing process interrupted.
      DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc "Stops a game without closing its archive: the game carries on elsewhere."
  @spec drop_game(String.t()) :: :ok | {:error, :not_found}
  def drop_game(room_code) do
    with {:ok, pid} <- GameRegistry.lookup(room_code),
         do: DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  Gets the PID for a game process by room code.

  ## Parameters

    - `room_code` - The room code to lookup

  ## Returns

    - `{:ok, pid}` if the game exists
    - `{:error, :not_found}` if no game is registered

  ## Examples

      iex> GameSupervisor.get_game("A3F9")
      {:ok, #PID<0.234.0>}

      iex> GameSupervisor.get_game("INVALID")
      {:error, :not_found}
  """
  @spec get_game(room_code :: String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_game(room_code) do
    GameRegistry.lookup(room_code)
  end

  @doc """
  Lists all active game PIDs.

  Returns a list of PIDs for all games currently supervised by this supervisor.

  ## Returns

    A list of PIDs

  ## Examples

      iex> GameSupervisor.list_games()
      [#PID<0.234.0>, #PID<0.235.0>, #PID<0.236.0>]
  """
  @spec list_games() :: [pid()]
  def list_games do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end
