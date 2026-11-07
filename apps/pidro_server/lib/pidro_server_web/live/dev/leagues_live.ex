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
      <section class="rounded-lg border border-stone-200 bg-white p-4">
        <h2 class="text-base font-semibold">Pairs sharing a table more than 10 times this week</h2>
        <p :if={@report.pairs == []} class="mt-2 text-sm text-stone-600">
          No repeated pairs above the threshold.
        </p>
        <p :for={pair <- @report.pairs} class="mt-2 text-sm">
          {pair.a} / {pair.b}: {pair.games} games
        </p>
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

  defp stamp(nil), do: "—"
  defp stamp(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp share(%{total: 0}, _league), do: 0.0

  defp share(report, league),
    do: Float.round(100 * Map.get(report.distribution, league, 0) / report.total, 1)
end
