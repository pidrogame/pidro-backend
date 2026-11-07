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
     |> assign(:connection_reports, for(days <- [7, 30], do: {days, PidroServer.Stats.connection_analytics(days)}))
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

  def handle_info(message, socket) do
    PidroServer.Games.UnexpectedMessage.report_once(__MODULE__, message)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="analytics"
      title="Analytics"
      flash={@flash}
    >
      <section id="connection-analytics" class="rounded-lg border border-stone-200 bg-white p-4 sm:p-6">
        <h2 class="text-base font-semibold text-stone-950">Connections and human tables</h2>
        <p class="mt-1 text-xs text-stone-600">Poor connection: share of recorded player time, graded per player and app version. Insufficient data is separate.</p>
        <p class="mt-1 text-xs text-stone-600">Bot-played turns: timer or stand-in bids, passes and cards / all such turns at human tables. Original bots count only in the total.</p>
        <p class="mt-1 text-xs text-stone-600">All other humans finished: the other humans at first takeover were connected and foreground at game end, with no deliberate departure. Temporary drops are allowed. Closed tables count as not finished; solo takeovers are excluded.</p>
        <p class="mt-1 text-xs text-stone-600">Finished or closed tables only, counted once per represented platform/version. Restored tables and incomplete accounting are excluded. Refresh for new results.</p>
        <div class="mt-4 grid gap-6 lg:grid-cols-2">
          <div :for={{days, rows} <- @connection_reports} data-connection-period={days}>
            <h3 class="text-sm font-semibold">Last {days} days</h3>
            <p :if={rows == []} class="mt-2 text-sm text-stone-600">No measured games yet.</p>
            <ul class="mt-2 divide-y divide-stone-200 text-sm">
              <li :for={row <- rows} class="space-y-2 py-3">
                <p class="font-semibold">{row.platform || "unknown platform"} · {row.app_version || "unknown version"}</p>
                <p>{Float.round(row.poor_percent / 1, 1)}% poor · {Float.round(row.unknown_percent / 1, 1)}% insufficient · {Float.round(row.duration_seconds / 3600, 1)} h</p>
                <dl class="grid gap-2 sm:grid-cols-2">
                  <div class="rounded-md bg-stone-50 p-3">
                    <dt class="text-xs text-stone-600">Bot-played turns</dt>
                    <dd class="text-lg font-semibold">{if row.bot_turn_percent, do: "#{Float.round(row.bot_turn_percent / 1, 1)}%", else: "—"}</dd>
                    <dd class="text-xs text-stone-600">{row.bot_turns} / {row.turns} turns</dd>
                  </div>
                  <div class="rounded-md bg-stone-50 p-3">
                    <dt class="text-xs text-stone-600">All other humans finished</dt>
                    <dd class="text-lg font-semibold">{if row.others_finished_percent, do: "#{Float.round(row.others_finished_percent / 1, 1)}%", else: "—"}</dd>
                    <dd class="text-xs text-stone-600">{row.takeover_games} takeover games<%= if row.others_finished_percent do %> · {Float.round((100 - row.others_finished_percent) / 1, 1)}% did not finish<% end %></dd>
                  </div>
                </dl>
              </li>
            </ul>
          </div>
        </div>
      </section>

      <div class="rounded-lg border border-stone-200 bg-white p-4 sm:p-6">
        <h2 class="text-base font-semibold text-stone-950">Server status</h2>
        <div class="mt-4">
          <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-3">
            <div>
              <dt class="text-xs font-medium text-stone-600">
                Status
              </dt>
              <dd class="mt-1">
                <span class="inline-flex rounded-sm bg-green-100 px-2 py-1 text-xs font-bold text-green-800">
                  Running
                </span>
              </dd>
            </div>
            <div>
              <dt class="text-xs font-medium text-stone-600">
                Uptime
              </dt>
              <dd class="mt-1 text-sm font-bold text-stone-900">
                {format_uptime(@uptime_seconds)}
              </dd>
            </div>
            <div>
              <dt class="text-xs font-medium text-stone-600">
                Current Time (UTC)
              </dt>
              <dd class="mt-1 font-mono text-sm text-stone-900">
                {Calendar.strftime(@current_time, "%Y-%m-%d %H:%M:%S")}
              </dd>
            </div>
          </dl>
        </div>
      </div>

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

      <div class="rounded-lg border border-stone-200 bg-white p-4 sm:p-6">
        <h2 class="text-base font-semibold text-stone-950">Room status breakdown</h2>
        <div class="mt-4">
          <div class="space-y-4">
            <%= for {status, count} <- @stats.by_status do %>
              <div>
                <div class="flex items-center justify-between mb-1">
                  <span class="text-sm font-medium text-stone-700 capitalize">{status}</span>
                  <span class="text-sm text-stone-600">{count} rooms</span>
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

      <div class="rounded-lg border border-stone-200 bg-white p-4 sm:p-6">
        <h2 class="text-base font-semibold text-stone-950">System information</h2>
        <div class="mt-4">
          <dl class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-2">
            <div>
              <dt class="text-sm font-medium text-stone-600">Elixir Version</dt>
              <dd class="mt-1 text-sm text-stone-950">{System.version()}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-stone-600">OTP Version</dt>
              <dd class="mt-1 text-sm text-stone-950">{:erlang.system_info(:otp_release)}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-stone-600">Total Processes</dt>
              <dd class="mt-1 text-sm text-stone-950">{:erlang.system_info(:process_count)}</dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-stone-600">Memory Usage</dt>
              <dd class="mt-1 text-sm text-stone-950">
                {format_memory(:erlang.memory(:total))}
              </dd>
            </div>
          </dl>
        </div>
      </div>

      <div class="text-sm text-stone-600">
        <span class="inline-flex items-center">
          <span class="mr-2 size-2 rounded-full bg-emerald-500 motion-safe:animate-pulse"></span>
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
