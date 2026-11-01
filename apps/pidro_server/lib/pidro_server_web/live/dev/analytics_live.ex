defmodule PidroServerWeb.Dev.AnalyticsLive do
  @moduledoc """
  Development analytics dashboard for monitoring server metrics and game statistics.

  This LiveView provides real-time analytics including:
  - Server status and uptime
  - Game statistics (total rooms, active games, waiting rooms, finished games)
  - Room status breakdown
  - System information

  The dashboard subscribes to lobby updates and refreshes metrics every second
  for live monitoring during development.
  """

  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Games.RoomManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to lobby updates for live stats
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
      # Schedule periodic refresh for uptime and other metrics
      :timer.send_interval(1000, self(), :tick)
    end

    {:ok,
     socket
     |> assign(:page_title, "Analytics Dashboard")
     |> assign(:uptime_seconds, node_uptime_seconds())
     |> assign(:current_time, DateTime.utc_now())
     |> load_stats()}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply,
     socket
     |> assign(:uptime_seconds, node_uptime_seconds())
     |> assign(:current_time, DateTime.utc_now())}
  end

  @impl true
  def handle_info({:lobby_update, _available_rooms}, socket) do
    # Reload stats whenever lobby updates
    {:noreply, load_stats(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="analytics"
      title="Development Analytics"
      subtitle="Monitor server health, room status, process count, memory, and live game volume while testing."
      flash={@flash}
    >
      <:actions>
        <.link
          navigate={~p"/admin/games"}
          class="inline-flex items-center gap-2 rounded-sm border border-stone-300 bg-white px-3 py-2 text-sm font-bold text-stone-700 shadow-sm hover:border-orange-300 hover:text-stone-950"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Games
        </.link>
      </:actions>

    <!-- Server Status -->
      <div class="overflow-hidden rounded-md border border-stone-300 bg-white shadow-sm">
        <div class="px-4 py-3">
          <h3 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
            Server Status
          </h3>
        </div>
        <div class="border-t border-stone-200 px-4 py-4">
          <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-3">
            <div>
              <dt class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
                Status
              </dt>
              <dd class="mt-1">
                <span class="inline-flex rounded-sm bg-green-100 px-2 py-1 text-xs font-bold text-green-800">
                  Running
                </span>
              </dd>
            </div>
            <div>
              <dt class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
                Uptime
              </dt>
              <dd class="mt-1 text-sm font-bold text-stone-900">
                {format_uptime(@uptime_seconds)}
              </dd>
            </div>
            <div>
              <dt class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
                Current Time (UTC)
              </dt>
              <dd class="mt-1 font-mono text-sm text-stone-900">
                {Calendar.strftime(@current_time, "%Y-%m-%d %H:%M:%S")}
              </dd>
            </div>
          </dl>
        </div>
      </div>

    <!-- Game Statistics -->
      <dl class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.stat_card
          label="Total rooms"
          value={@stats.total_rooms}
          hint="All RoomManager entries"
          icon="hero-square-3-stack-3d"
          tone="orange"
        />
        <.stat_card
          label="Active games"
          value={@stats.active_games}
          hint="Currently playing"
          icon="hero-play"
          tone="green"
        />
        <.stat_card
          label="Waiting rooms"
          value={@stats.waiting_rooms}
          hint="Open lobbies"
          icon="hero-clock"
        />
        <.stat_card
          label="Finished games"
          value={@stats.finished_games}
          hint="Cleanup candidates"
          icon="hero-flag"
          tone="blue"
        />
      </dl>

    <!-- Room Status Breakdown -->
      <div class="overflow-hidden rounded-md border border-stone-300 bg-white shadow-sm">
        <div class="px-4 py-3">
          <h3 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
            Room Status Breakdown
          </h3>
        </div>
        <div class="border-t border-stone-200 px-4 py-4">
          <div class="space-y-4">
            <%= for {status, count} <- @stats.by_status do %>
              <div>
                <div class="flex items-center justify-between mb-1">
                  <span class="text-sm font-medium text-zinc-700 capitalize">{status}</span>
                  <span class="text-sm text-zinc-500">{count} rooms</span>
                </div>
                <div class="w-full bg-zinc-200 rounded-full h-2">
                  <div
                    class={"h-2 rounded-full #{status_bar_color(status)}"}
                    style={"width: #{calculate_percentage(count, @stats.total_rooms)}%"}
                  >
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

    <!-- System Information -->
      <div class="overflow-hidden rounded-md border border-stone-300 bg-white shadow-sm">
        <div class="px-4 py-3">
          <h3 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
            System Information
          </h3>
        </div>
        <div class="border-t border-stone-200 px-4 py-4">
          <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-2">
            <div>
              <dt class="text-sm font-medium text-zinc-500">Elixir Version</dt>
              <dd class="mt-1 text-sm text-zinc-900">{System.version()}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-zinc-500">OTP Version</dt>
              <dd class="mt-1 text-sm text-zinc-900">{:erlang.system_info(:otp_release)}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-zinc-500">Total Processes</dt>
              <dd class="mt-1 text-sm text-zinc-900">{:erlang.system_info(:process_count)}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-zinc-500">Memory Usage</dt>
              <dd class="mt-1 text-sm text-zinc-900">
                {format_memory(:erlang.memory(:total))}
              </dd>
            </div>
          </dl>
        </div>
      </div>

    <!-- Auto-refresh indicator -->
      <div class="text-center text-sm text-stone-500">
        <span class="inline-flex items-center">
          <span class="h-2 w-2 bg-green-500 rounded-full mr-2 animate-pulse"></span>
          Live updates enabled (refreshing every second)
        </span>
      </div>
    </.admin_shell>
    """
  end

  # Private functions

  defp load_stats(socket) do
    rooms = RoomManager.list_rooms(:all)

    by_status =
      rooms
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {status, rooms_list} -> {status, length(rooms_list)} end)
      |> Enum.into(%{})

    stats = %{
      total_rooms: length(rooms),
      active_games: Enum.count(rooms, &(&1.status == :playing)),
      waiting_rooms: Enum.count(rooms, &(&1.status == :waiting)),
      finished_games: Enum.count(rooms, &(&1.status == :finished)),
      by_status: by_status
    }

    assign(socket, :stats, stats)
  end

  # Wall-clock time since the Erlang node started, i.e. since the last
  # deploy or restart. Not since this LiveView mounted.
  defp node_uptime_seconds do
    {uptime_ms, _since_last_call} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  defp format_uptime(diff) when is_integer(diff) do
    hours = div(diff, 3600)
    minutes = div(rem(diff, 3600), 60)
    seconds = rem(diff, 60)

    "#{hours}h #{minutes}m #{seconds}s"
  end

  defp calculate_percentage(count, total) when total > 0 do
    Float.round(count / total * 100, 1)
  end

  defp calculate_percentage(_count, _total), do: 0

  defp status_bar_color(status) do
    case status do
      :waiting -> "bg-yellow-500"
      :ready -> "bg-blue-500"
      :playing -> "bg-green-500"
      :finished -> "bg-gray-500"
      :closed -> "bg-red-500"
      _ -> "bg-gray-300"
    end
  end

  defp format_memory(bytes) do
    mb = bytes / 1_024 / 1_024
    "#{Float.round(mb, 2)} MB"
  end
end
