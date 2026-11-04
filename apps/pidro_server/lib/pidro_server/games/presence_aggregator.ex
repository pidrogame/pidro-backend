defmodule PidroServer.Games.PresenceAggregator do
  @moduledoc """
  Tracks unique online users across lobby and game channels.

  Maintains an aggregate count of connected users with breakdown by activity
  (lobby, playing, spectating). Debounces count broadcasts to avoid flooding
  clients during rapid join/leave activity.

  Channels call `track/2` when a user joins. The aggregator monitors the
  calling process and automatically cleans up when it exits (disconnect).

  ## Usage

      # In LobbyChannel :after_join
      PresenceAggregator.track(user_id, :lobby)

      # In GameChannel :after_join
      PresenceAggregator.track(user_id, :playing)

      # Synchronous count query
      PresenceAggregator.get_count()
      #=> 42

      # Full breakdown
      PresenceAggregator.get_breakdown()
      #=> %{lobby: 20, playing: 18, spectating: 4}
  """

  use GenServer

  alias PidroServer.Games.Lifecycle

  @type activity :: :lobby | :playing | :spectating

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track a user's presence from the calling process.

  The aggregator monitors the calling process and automatically removes
  the tracking entry when it exits. A single user connected from multiple
  channels (e.g., lobby + game) is counted once in the unique user count.

  Bot user IDs (starting with "bot_") are excluded.
  """
  @spec track(String.t(), activity()) :: :ok
  def track(user_id, activity) when activity in [:lobby, :playing, :spectating] do
    GenServer.cast(__MODULE__, {:track, user_id, activity, self()})
  end

  @doc """
  Returns the count of unique online users.
  """
  @spec get_count() :: non_neg_integer()
  def get_count do
    GenServer.call(__MODULE__, :get_count)
  end

  @doc """
  Returns the count of unique online users with breakdown by activity.

  Each user appears in exactly one category based on priority:
  playing > spectating > lobby.
  """
  @spec get_breakdown() :: %{
          lobby: non_neg_integer(),
          playing: non_neg_integer(),
          spectating: non_neg_integer()
        }
  def get_breakdown do
    GenServer.call(__MODULE__, :get_breakdown)
  end

  @doc "Returns unique connected human IDs with their primary activity for admin monitoring."
  def online_users, do: GenServer.call(__MODULE__, :online_users)

  @doc false
  def reset_for_test do
    GenServer.call(__MODULE__, :reset_for_test)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %{
      # %{pid => {user_id, activity, monitor_ref}}
      connections: %{},
      # %{user_id => MapSet.t(pid)}
      user_pids: %{},
      debounce_timer: nil,
      last_broadcast_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:track, user_id, activity, pid}, state) do
    if bot_user?(user_id) do
      {:noreply, state}
    else
      state = do_track(state, user_id, activity, pid)
      {:noreply, maybe_schedule_broadcast(state)}
    end
  end

  @impl true
  def handle_call(:online_users, _from, state) do
    users = Map.new(state.user_pids, fn {id, pids} -> {id, primary_activity(state, pids)} end)
    {:reply, users, state}
  end

  def handle_call(:get_count, _from, state) do
    {:reply, count_unique_users(state), state}
  end

  def handle_call(:get_breakdown, _from, state) do
    {:reply, compute_breakdown(state), state}
  end

  def handle_call(:reset_for_test, _from, state) do
    # Demonitor all tracked processes
    for {_pid, {_user_id, _activity, ref}} <- state.connections do
      Process.demonitor(ref, [:flush])
    end

    if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)

    {:reply, :ok,
     %{connections: %{}, user_pids: %{}, debounce_timer: nil, last_broadcast_count: 0}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = do_untrack(state, pid)
    {:noreply, maybe_schedule_broadcast(state)}
  end

  def handle_info(:broadcast_count, state) do
    count = count_unique_users(state)
    breakdown = compute_breakdown(state)

    if count != state.last_broadcast_count do
      Phoenix.PubSub.broadcast(
        PidroServer.PubSub,
        "lobby:updates",
        {:online_count_updated, %{count: count, breakdown: breakdown}}
      )
    end

    {:noreply, %{state | debounce_timer: nil, last_broadcast_count: count}}
  end

  # Private helpers

  defp do_track(state, user_id, activity, pid) do
    case Map.get(state.connections, pid) do
      {^user_id, _old_activity, ref} ->
        # Same pid re-tracking with new activity — update in place
        %{state | connections: Map.put(state.connections, pid, {user_id, activity, ref})}

      nil ->
        # New connection — monitor and track
        ref = Process.monitor(pid)

        state
        |> put_in([:connections, Access.key(pid)], {user_id, activity, ref})
        |> update_in([:user_pids], fn user_pids ->
          Map.update(user_pids, user_id, MapSet.new([pid]), &MapSet.put(&1, pid))
        end)
    end
  end

  defp do_untrack(state, pid) do
    case Map.pop(state.connections, pid) do
      {nil, _connections} ->
        state

      {{user_id, _activity, ref}, connections} ->
        Process.demonitor(ref, [:flush])

        user_pids =
          case Map.get(state.user_pids, user_id) do
            nil ->
              state.user_pids

            pids ->
              remaining = MapSet.delete(pids, pid)

              if MapSet.size(remaining) == 0 do
                Map.delete(state.user_pids, user_id)
              else
                Map.put(state.user_pids, user_id, remaining)
              end
          end

        %{state | connections: connections, user_pids: user_pids}
    end
  end

  defp count_unique_users(state) do
    map_size(state.user_pids)
  end

  defp compute_breakdown(state) do
    state.user_pids
    |> Enum.reduce(%{lobby: 0, playing: 0, spectating: 0}, fn {_user_id, pids}, acc ->
      activity = primary_activity(state, pids)
      Map.update!(acc, activity, &(&1 + 1))
    end)
  end

  defp primary_activity(state, pids) do
    activities =
      pids
      |> Enum.map(fn pid ->
        case Map.get(state.connections, pid) do
          {_user_id, activity, _ref} -> activity
          nil -> :lobby
        end
      end)
      |> MapSet.new()

    cond do
      :playing in activities -> :playing
      :spectating in activities -> :spectating
      true -> :lobby
    end
  end

  defp maybe_schedule_broadcast(%{debounce_timer: nil} = state) do
    timer = Process.send_after(self(), :broadcast_count, Lifecycle.config(:presence_debounce_ms))
    %{state | debounce_timer: timer}
  end

  defp maybe_schedule_broadcast(state) do
    # Timer already scheduled — it will pick up the latest count
    state
  end

  defp bot_user?(user_id) when is_binary(user_id) do
    String.starts_with?(user_id, "bot_")
  end

  defp bot_user?(_), do: true
end
