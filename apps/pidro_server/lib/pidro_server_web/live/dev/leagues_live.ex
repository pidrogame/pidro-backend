defmodule PidroServerWeb.Dev.LeaguesLive do
  @moduledoc "Admin-only league operations; manual settlement exists only in dev."
  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents
  alias PidroServer.Leagues
  alias PidroServer.Leagues.Report
  @dev Application.compile_env(:pidro_server, :dev_routes, false)
  @targets %{"deuce" => 13, "ten" => 22, "jack" => 29, "ace" => 26, "pidro" => 8}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Leagues",
       report: Report.build(),
       leagues: Leagues.leagues(),
       targets: @targets,
       dev: @dev
     )}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, assign(socket, report: Report.build())}

  if @dev do
    @impl true
    def handle_event("close", %{"moment" => moment}, socket) do
      case DateTime.from_iso8601(moment) do
        {:ok, at, 0} ->
          case Leagues.dev_close(at) do
            {:ok, count} ->
              {:noreply,
               socket
               |> put_flash(:info, "Closed #{count} week(s).")
               |> assign(report: Report.build())}

            _ ->
              {:noreply, put_flash(socket, :error, "Use a Sunday at 19:00 UTC.")}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "Use an ISO-8601 UTC close moment.")}
      end
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="leagues"
      title="Weekly leagues"
      subtitle="Closes every Sunday 19:00 UTC"
      flash={@flash}
    >
      <:actions>
        <button
          phx-click="refresh"
          class="rounded-md border border-stone-300 bg-white px-3 py-2 text-sm font-medium text-stone-800 hover:bg-stone-100"
        >Refresh</button>
      </:actions>
      <div id="league-gate" class="rounded-lg border border-stone-200 bg-white p-4 text-sm">
        <strong>{if @report.on, do: "On", else: "Off"}</strong>
        <span class="ml-2 text-stone-600">Start: {stamp(@report.since)} · Next close: {stamp(
          @report.closes_at
        )}</span>
        <p class="mt-2">
          Last week's players placed: {@report.participation.placed} / {@report.participation.played} ({@report.participation.percent}%). Includes solo games and guests in the denominator.
        </p>
      </div>
      <section class="overflow-x-auto rounded-lg border border-stone-200 bg-white">
        <h2 class="px-4 py-3 text-base font-semibold">Distribution and this week's rooms</h2>
        <table
          id="league-distribution"
          class="min-w-full text-sm [&_td]:px-4 [&_td]:py-2 [&_th]:px-4 [&_th]:py-2"
        >
          <thead class="bg-stone-50 text-xs font-medium text-stone-600">
            <tr>
              <th class="text-left">League</th><th class="text-right">Players / share</th><th class="text-right">
                Target
              </th><th class="text-right">Rooms</th><th class="text-right">Members</th><th class="text-right">
                Last up
              </th><th class="text-right">Last down</th>
            </tr>
          </thead>
          <tbody class="text-right">
            <tr :for={league <- @leagues} class="border-t border-stone-100">
              <td class="text-left font-medium">{String.capitalize(league)}</td>
              <td>{Map.get(@report.distribution, league, 0)} / {share(@report, league)}%</td><td>
                ~{@targets[league]}%
              </td>
              <td>{Enum.count(@report.rooms, &(&1.league == league))}</td><td>
                {@report.rooms
                |> Enum.filter(&(&1.league == league))
                |> Enum.map(& &1.members)
                |> Enum.sum()}
              </td>
              <td>{Map.get(@report.movement, {league, "up"}, 0)}</td><td>
                {Map.get(@report.movement, {league, "down"}, 0)}
              </td>
            </tr>
          </tbody>
        </table>
        <p class="border-t border-stone-100 px-4 py-3 text-xs text-stone-600">
          Last close: {stamp(@report.last_close)}. Distribution includes all registered accounts; no row means Deuce.
        </p>
      </section>
      <section class="overflow-x-auto rounded-lg border border-stone-200 bg-white">
        <h2 class="px-4 py-3 text-base font-semibold">Room placement times</h2>
        <table
          id="league-rooms"
          class="min-w-full text-sm [&_td]:px-4 [&_td]:py-2 [&_th]:px-4 [&_th]:py-2"
        >
          <thead class="bg-stone-50 text-left text-xs font-medium text-stone-600">
            <tr>
              <th>League / room</th><th class="text-right">Members</th><th>Oldest (UTC)</th><th>
                Newest (UTC)
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={room <- @report.rooms} class="border-t border-stone-100">
              <td>{room.league} · {String.slice(room.id, 0, 8)}</td><td class="text-right">
                {room.members}
              </td><td>{stamp(room.oldest)}</td><td>{stamp(room.newest)}</td>
            </tr>
          </tbody>
        </table>
      </section>
      <section
        id="league-pairs"
        aria-labelledby="league-pairs-title"
        class="rounded-lg border border-stone-200 bg-white"
      >
        <header class="px-4 py-3">
          <h2 id="league-pairs-title" class="text-base font-semibold">Frequent tablemates</h2>
          <p class="mt-0.5 text-sm text-stone-600">
            Pairs who shared 11 or more completed games this league week.
          </p>
        </header>
        <p
          :if={@report.pairs == []}
          class="border-t border-stone-200 px-4 py-4 text-sm text-stone-600"
        >
          No pairs have reached 11 games yet.
        </p>
        <ul :if={@report.pairs != []} class="divide-y divide-stone-200 border-t border-stone-200">
          <li
            :for={pair <- @report.pairs}
            class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-2 px-4 py-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_15rem]"
          >
            <.pair_player :for={player <- pair.players} player={player} />
            <div class="col-start-2 row-span-2 row-start-1 text-right tabular-nums sm:col-start-3 sm:row-span-1">
              <p class="text-sm text-stone-700">
                <strong class="text-lg font-semibold text-stone-950">{pair.games}</strong> games
              </p>
              <p class="text-xs leading-5 text-stone-600">
                <span :if={pair.unknown < pair.games}>
                  <span class="block sm:inline">{pair.teammates} as teammates</span>
                  <span aria-hidden="true" class="hidden sm:inline"> · </span>
                  <span>{pair.opponents} as opponents</span>
                </span>
                <span :if={pair.unknown > 0} class="block">{pair.unknown} without team data</span>
              </p>
            </div>
          </li>
        </ul>
      </section>
      <form
        :if={@dev}
        id="league-close"
        phx-submit="close"
        class="flex flex-wrap items-end gap-3 rounded-lg border border-amber-200 bg-amber-50 p-4"
      >
        <label class="text-sm">Dev only: close through Sunday (UTC)<input
          name="moment"
          aria-label="Close moment"
          value={DateTime.to_iso8601(@report.starts_at)}
          class="mt-1 block w-72 max-w-full rounded-md border border-stone-300 bg-white px-3 py-2"
        /></label>
        <button
          type="submit"
          class="rounded-md bg-stone-950 px-3 py-2 text-sm font-medium text-white hover:bg-stone-800"
        >Run close</button>
      </form>
    </.admin_shell>
    """
  end

  attr :player, :map, required: true

  defp pair_player(assigns) do
    ~H"""
    <div class="min-w-0">
      <.link
        :if={@player.name}
        navigate={~p"/admin/users/#{@player.id}"}
        class="group inline-flex max-w-full items-center gap-2.5 rounded-sm"
      >
        <span
          aria-hidden="true"
          class="relative grid size-9 shrink-0 place-items-center overflow-hidden rounded-full bg-sky-100 text-sm font-semibold text-sky-900"
        >
          {String.upcase(String.first(@player.name))}
          <img
            :if={@player.avatar_url}
            src={@player.avatar_url}
            alt=""
            loading="lazy"
            class="absolute inset-0 size-full object-cover"
            onerror="this.hidden=true"
            onload="this.hidden=false"
          />
        </span>
        <span class="min-w-0">
          <span class="block text-sm font-semibold text-sky-900 wrap-anywhere group-hover:underline">{@player.name}</span>
          <span class="block text-xs text-stone-600">Level {@player.level}</span>
        </span>
      </.link>
      <span :if={!@player.name} class="flex items-center gap-2.5">
        <span class="grid size-9 shrink-0 place-items-center rounded-full bg-stone-100 text-stone-500">
          <.icon name="hero-user" class="size-4" />
        </span>
        <span>
          <span class="block text-sm font-medium">Unknown player</span>
          <span title={@player.id} class="block text-xs text-stone-600">{String.slice(
            @player.id,
            0,
            8
          )}</span>
        </span>
      </span>
    </div>
    """
  end

  defp stamp(nil), do: "—"
  defp stamp(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp share(%{total: 0}, _league), do: 0.0

  defp share(report, league),
    do: Float.round(100 * Map.get(report.distribution, league, 0) / report.total, 1)
end
