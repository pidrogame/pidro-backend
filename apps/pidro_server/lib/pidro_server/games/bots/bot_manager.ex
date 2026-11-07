defmodule PidroServer.Games.Bots.BotManager do
  @moduledoc """
  GenServer that tracks and manages all bot players across all games.

  Provides a centralized way to manage bot players for gameplay, testing,
  and development purposes.

  ## Architecture

  The BotManager uses both a GenServer state and an ETS table for fast lookups:
  - GenServer state: `%{game_id => %{position => bot_pid}}`
  - ETS table: `:pidro_bots` with key `{room_code, position}` and value `bot_pid`

  Bot processes are supervised by `PidroServer.Games.Bots.BotSupervisor` and the
  BotManager monitors them to handle crashes gracefully.

  ## Usage

      {:ok, pid} = BotManager.start_bot("A3F9", :north, :random)
      {:ok, pid} = BotManager.start_bot("A3F9", :north, :random, 250)
      :ok = BotManager.stop_bot("A3F9", :north)
      :ok = BotManager.stop_all_bots("A3F9")
      :ok = BotManager.pause_bot("A3F9", :north)
      :ok = BotManager.resume_bot("A3F9", :north)
      bots = BotManager.list_bots("A3F9")
  """

  use GenServer
  require Logger

  @table_name :pidro_bots

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @spec start_bots(String.t(), pos_integer(), atom()) ::
          {:ok, [pid()]} | {:error, term()}
  def start_bots(room_code, bot_count, strategy)
      when bot_count >= 1 and bot_count <= 4 do
    start_bots(room_code, bot_count, strategy, nil)
  end

  @spec start_bots(String.t(), pos_integer(), atom(), non_neg_integer() | nil) ::
          {:ok, [pid()]} | {:error, term()}
  def start_bots(room_code, bot_count, strategy, delay_ms)
      when bot_count >= 1 and bot_count <= 4 do
    alias PidroServer.Games.RoomManager
    alias PidroServer.Games.Room.Positions

    with {:ok, room} <- RoomManager.owned_room(room_code) do
      empty_seats = Positions.available(room)

      if length(empty_seats) < bot_count do
        {:error, :not_enough_seats}
      else
        empty_seats
        |> Enum.take(bot_count)
        |> Enum.reduce_while({:ok, []}, fn position, {:ok, pids} ->
          case start_bot(room_code, position, strategy, delay_ms) do
            {:ok, pid} -> {:cont, {:ok, [pid | pids]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, pids} -> {:ok, Enum.reverse(pids)}
          error -> error
        end
      end
    end
  end

  @spec start_bot(String.t(), atom(), atom()) ::
          {:ok, pid()} | {:error, term()}
  def start_bot(room_code, position, strategy)
      when position in [:north, :east, :south, :west] and strategy in [:random, :basic, :smart] do
    start_bot(room_code, position, strategy, nil)
  end

  @spec start_bot(String.t(), atom(), atom(), non_neg_integer() | nil) ::
          {:ok, pid()} | {:error, term()}
  def start_bot(room_code, position, strategy, delay_ms)
      when position in [:north, :east, :south, :west] and
             strategy in [:random, :basic, :smart] and
             (is_nil(delay_ms) or (is_integer(delay_ms) and delay_ms >= 0 and delay_ms <= 5000)) do
    # Callers read the room next, so the bot has taken its seat by the time this returns.
    with {:ok, pid} <-
           GenServer.call(__MODULE__, {:start_bot, room_code, position, strategy, delay_ms}) do
      PidroServer.Games.Bots.BotPlayer.await_join(pid)
      {:ok, pid}
    end
  end

  @doc "The pid registered for a bot slot, or `nil`. Reads the slot table directly."
  @spec bot_pid(String.t(), atom()) :: pid() | nil
  def bot_pid(room_code, position) do
    case :ets.lookup(@table_name, {room_code, position}) do
      [{_key, pid}] -> pid
      [] -> nil
    end
  end

  @spec stop_bot(String.t(), atom()) :: :ok | {:error, :not_found}
  def stop_bot(room_code, position) when position in [:north, :east, :south, :west] do
    GenServer.call(__MODULE__, {:stop_bot, room_code, position})
  end

  @spec stop_all_bots(String.t()) :: :ok
  def stop_all_bots(room_code) do
    GenServer.call(__MODULE__, {:stop_all_bots, room_code})
  end

  @spec pause_bot(String.t(), atom()) :: :ok | {:error, :not_found}
  def pause_bot(room_code, position) when position in [:north, :east, :south, :west] do
    GenServer.call(__MODULE__, {:pause_bot, room_code, position})
  end

  @spec resume_bot(String.t(), atom()) :: :ok | {:error, :not_found}
  def resume_bot(room_code, position) when position in [:north, :east, :south, :west] do
    GenServer.call(__MODULE__, {:resume_bot, room_code, position})
  end

  @spec list_bots(String.t()) :: %{atom() => %{pid: pid(), strategy: atom(), status: atom()}}
  def list_bots(room_code) do
    GenServer.call(__MODULE__, {:list_bots, room_code})
  end

  ## GenServer Callbacks

  @impl true
  def init(:ok) do
    table = :ets.new(@table_name, [:set, :public, :named_table])
    Logger.info("BotManager started with ETS table #{inspect(table)}")
    {:ok, %{bots: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:start_bot, room_code, position, strategy, delay_ms}, _from, state) do
    case :ets.lookup(@table_name, {room_code, position}) do
      [{_key, _existing_pid}] ->
        {:reply, {:error, :already_exists}, state}

      [] ->
        bot_spec =
          {PidroServer.Games.Bots.BotPlayer,
           [room_code: room_code, position: position, strategy: strategy]
           |> maybe_put_delay_override(delay_ms)}

        case DynamicSupervisor.start_child(PidroServer.Games.Bots.BotSupervisor, bot_spec) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            :ets.insert(@table_name, {{room_code, position}, pid})

            bot_info = %{pid: pid, strategy: strategy, delay_ms: delay_ms, paused: false}
            new_bots = add_bot_to_state(state.bots, room_code, position, bot_info)
            new_monitors = Map.put(state.monitors, ref, {room_code, position, pid})

            Logger.info(
              "Started bot for room #{room_code}, position #{position}, strategy #{strategy}, pacing #{format_pacing(delay_ms)}"
            )

            {:reply, {:ok, pid}, %{state | bots: new_bots, monitors: new_monitors}}

          {:error, reason} = error ->
            Logger.error("Failed to start bot: #{inspect(reason)}")
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:stop_bot, room_code, position}, _from, state) do
    case :ets.lookup(@table_name, {room_code, position}) do
      [{_key, pid}] ->
        # Clean up synchronously to avoid stop→start race
        state = cleanup_bot(state, room_code, position, pid)
        DynamicSupervisor.terminate_child(PidroServer.Games.Bots.BotSupervisor, pid)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:stop_all_bots, room_code}, _from, state) do
    positions = Map.get(state.bots, room_code, %{})

    state =
      Enum.reduce(positions, state, fn {position, bot_info}, acc ->
        acc = cleanup_bot(acc, room_code, position, bot_info.pid)
        DynamicSupervisor.terminate_child(PidroServer.Games.Bots.BotSupervisor, bot_info.pid)
        acc
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:pause_bot, room_code, position}, _from, state) do
    case :ets.lookup(@table_name, {room_code, position}) do
      [{_key, pid}] ->
        send(pid, :pause)

        new_bots =
          Map.update(state.bots, room_code, %{}, fn positions ->
            Map.update(positions, position, %{}, fn bot_info ->
              %{bot_info | paused: true}
            end)
          end)

        {:reply, :ok, %{state | bots: new_bots}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:resume_bot, room_code, position}, _from, state) do
    case :ets.lookup(@table_name, {room_code, position}) do
      [{_key, pid}] ->
        send(pid, :resume)

        new_bots =
          Map.update(state.bots, room_code, %{}, fn positions ->
            Map.update(positions, position, %{}, fn bot_info ->
              %{bot_info | paused: false}
            end)
          end)

        {:reply, :ok, %{state | bots: new_bots}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list_bots, room_code}, _from, state) do
    positions = Map.get(state.bots, room_code, %{})

    bots =
      Enum.reduce(positions, %{}, fn {position, bot_info}, acc ->
        Map.put(acc, position, %{
          pid: bot_info.pid,
          strategy: bot_info.strategy,
          status: if(bot_info.paused, do: :paused, else: :running)
        })
      end)

    {:reply, bots, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{room_code, position, ^pid}, new_monitors} ->
        Logger.info("Bot for room #{room_code}, position #{position} exited: #{inspect(reason)}")
        # A bot that dies without stop_bot (with its room, say) frees its slot here.
        :ets.delete_object(@table_name, {{room_code, position}, pid})
        state = %{state | monitors: new_monitors}
        {:noreply, cleanup_bot_state(state, room_code, position)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  ## Private Functions

  # Synchronous cleanup of ETS, state, and monitors for a single bot.
  # Called from stop_bot/stop_all_bots before terminating the child.
  defp cleanup_bot(state, room_code, position, pid) do
    :ets.delete(@table_name, {room_code, position})

    # Find and remove the monitor for this pid
    {ref, _} =
      Enum.find(state.monitors, {nil, nil}, fn {_ref, val} ->
        val == {room_code, position, pid}
      end)

    state =
      if ref do
        Process.demonitor(ref, [:flush])
        %{state | monitors: Map.delete(state.monitors, ref)}
      else
        state
      end

    cleanup_bot_state(state, room_code, position)
  end

  # Remove a bot from the bots map, cleaning up empty room entries.
  defp cleanup_bot_state(state, room_code, position) do
    new_bots =
      Map.update(state.bots, room_code, %{}, fn positions ->
        Map.delete(positions, position)
      end)

    new_bots =
      if Map.get(new_bots, room_code) == %{} do
        Map.delete(new_bots, room_code)
      else
        new_bots
      end

    %{state | bots: new_bots}
  end

  defp add_bot_to_state(bots, room_code, position, bot_info) do
    Map.update(bots, room_code, %{position => bot_info}, fn positions ->
      Map.put(positions, position, bot_info)
    end)
  end

  defp maybe_put_delay_override(opts, nil), do: opts
  defp maybe_put_delay_override(opts, delay_ms), do: Keyword.put(opts, :delay_ms, delay_ms)

  defp format_pacing(nil), do: "runtime"
  defp format_pacing(delay_ms), do: "#{delay_ms}ms fixed"
end
