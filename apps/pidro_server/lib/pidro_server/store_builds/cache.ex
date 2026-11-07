defmodule PidroServer.StoreBuilds.Cache do
  @moduledoc "Node-local store snapshots. Apple polls; Play is manual unless explicitly enabled."
  use GenServer
  alias PidroServer.StoreBuilds.Client
  @topic "store_builds"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  def refresh(platform) when platform in ~w(ios android),
    do: GenServer.cast(__MODULE__, {:refresh, platform})

  def subscribe, do: Phoenix.PubSub.subscribe(PidroServer.PubSub, @topic)

  @impl true
  def init(_opts) do
    send(self(), :refresh)

    {:ok,
     %{
       stores:
         Map.new(
           ~w(ios android),
           &{&1,
            %{
              data: nil,
              error: if(Client.connected?(&1), do: nil, else: :not_connected),
              checked_at: nil,
              good_at: nil,
              refreshing: false
            }}
         ),
       tasks: %{}
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.stores, state}

  @impl true
  def handle_cast({:refresh, platform}, state), do: {:noreply, refresh_stores(state, [platform])}

  @impl true
  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, :timer.minutes(10))

    platforms =
      if Application.get_env(:pidro_server, __MODULE__, [])[:play_auto_refresh],
        do: ~w(ios android),
        else: ~w(ios)

    {:noreply, refresh_stores(state, platforms)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {platform, tasks} = Map.pop(state.tasks, ref)
    store = state.stores[platform]
    now = DateTime.utc_now(:second)

    store =
      case result do
        {:ok, data} ->
          %{store | data: data, error: nil, checked_at: now, good_at: now, refreshing: false}

        {:error, error} ->
          %{store | error: error, checked_at: now, refreshing: false}
      end

    {:noreply, broadcast(%{state | tasks: tasks, stores: Map.put(state.stores, platform, store)})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    handle_info({ref, {:error, "Store check failed. Try Refresh."}}, state)
  end

  defp refresh_stores(state, platforms) do
    Enum.reduce(platforms, state, fn platform, state ->
      if state.stores[platform].refreshing do
        state
      else
        task =
          Task.Supervisor.async_nolink(PidroServer.TaskSupervisor, fn ->
            Client.fetch(platform)
          end)

        %{
          state
          | tasks: Map.put(state.tasks, task.ref, platform),
            stores: put_in(state.stores, [platform, :refreshing], true)
        }
      end
    end)
    |> broadcast()
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(PidroServer.PubSub, @topic, {:store_builds, state.stores})
    state
  end
end
