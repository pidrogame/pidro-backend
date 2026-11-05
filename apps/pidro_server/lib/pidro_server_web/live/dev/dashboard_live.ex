defmodule PidroServerWeb.Dev.DashboardLive do
  @moduledoc "Read-only campaign desk, sampled with bounded refreshes."
  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents
  import Ecto.Query

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Games.{AdminGameSummary, PresenceAggregator, RoomManager}
  alias PidroServer.Repo

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :sample, 2_000)

    {:ok,
     socket
     |> assign(page_title: "Live overview", profiles: %{}, accounts_at: nil)
     |> sample()}
  end

  @impl true
  def handle_info(:sample, socket) do
    socket = sample(socket)
    Process.send_after(self(), :sample, 2_000)
    {:noreply, socket}
  end

  def handle_info(message, socket) do
    PidroServer.Games.UnexpectedMessage.report_once(__MODULE__, message)
    {:noreply, socket}
  end

  defp sample(socket) do
    now = DateTime.utc_now()
    online = PresenceAggregator.online_users()
    ids = online |> Map.keys() |> Enum.sort() |> Enum.take(50)
    valid_ids = Enum.filter(ids, &match?({:ok, _}, Ecto.UUID.dump(&1)))
    profiles = socket.assigns.profiles

    profiles =
      if Enum.sort(Map.keys(profiles)) == valid_ids,
        do: profiles,
        else: Auth.get_users_map(valid_ids)

    rooms = RoomManager.list_rooms(:all)

    tables =
      rooms
      |> Enum.reject(&(&1.status == :finished))
      |> Enum.map(fn room ->
        humans =
          Enum.count(room.seats, fn {_, seat} ->
            seat.occupant_type == :human and seat.status == :connected
          end)

        %{room: room, humans: humans, summary: AdminGameSummary.get(room.code)}
      end)
      |> Enum.sort_by(&{&1.humans == 0, &1.room.code})

    socket
    |> assign(
      now: now,
      online: online,
      profiles: profiles,
      roster: ids,
      breakdown: Enum.frequencies(Map.values(online)),
      tables: Enum.take(tables, 12),
      table_count: length(tables),
      live_tables: Enum.count(tables, &(&1.humans > 0)),
      unattended: Enum.count(tables, &(&1.humans == 0))
    )
    |> load_accounts(now)
  end

  defp load_accounts(socket, now) do
    if socket.assigns.accounts_at == nil or DateTime.diff(now, socket.assigns.accounts_at) >= 15 do
      start = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

      tomorrow = DateTime.add(start, 86_400, :second)

      hourly =
        Repo.all(
          from u in User,
            where: u.inserted_at >= ^start and u.inserted_at < ^tomorrow,
            group_by: [fragment("extract(hour from ?)", u.inserted_at), u.guest],
            select:
              {fragment("extract(hour from ?)::integer", u.inserted_at), u.guest, count(u.id)}
        )

      hourly = Map.new(hourly, fn {hour, guest, count} -> {{hour, guest}, count} end)

      bars =
        for hour <- 0..23 do
          registered = Map.get(hourly, {hour, false}, 0)
          guests = Map.get(hourly, {hour, true}, 0)
          %{hour: hour, registered: registered, guests: guests, total: registered + guests}
        end

      recent =
        Repo.all(
          from u in User,
            where: u.inserted_at >= ^start and u.inserted_at < ^tomorrow,
            order_by: [desc: u.inserted_at, desc: u.id],
            limit: 8
        )

      assign(socket,
        accounts_at: now,
        bars: bars,
        recent: recent,
        new_accounts: Enum.sum(Enum.map(bars, & &1.total)),
        new_guests: Enum.sum(Enum.map(bars, & &1.guests)),
        chart_max: max(Enum.max(Enum.map(bars, & &1.total)), 1)
      )
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="dashboard"
      title="Live overview"
      subtitle="The room is open. Follow the players, arrivals and tables as they happen."
      flash={@flash}
      class="campaign-desk"
    >
      <:actions>
        <div class="desk-refresh">
          <span class="desk-connected">● Connected</span><span class="desk-disconnected">Connection lost. Reconnecting…</span><time datetime={
            DateTime.to_iso8601(@now)
          }>Sampled {Calendar.strftime(@now, "%H:%M:%S")} UTC</time>
        </div>
      </:actions>
      <dl class="desk-totals">
        <div>
          <dt>Players online</dt><dd id="online-total">{map_size(@online)}</dd><span>Unique connections, bots excluded</span>
        </div>
        <div>
          <dt>New accounts today</dt><dd id="new-total">{@new_accounts}</dd><span>{@new_accounts -
            @new_guests} registered · {@new_guests} guests · UTC</span>
        </div>
        <div>
          <dt>Attended tables</dt><dd>{@live_tables}</dd><span>At least one connected human</span>
        </div>
      </dl>
      <div class="desk-main">
        <section class="desk-arrivals" aria-labelledby="arrivals-title">
          <div class="desk-heading">
            <div>
              <h2 id="arrivals-title">Today's arrivals</h2><p>
                New accounts by hour · {Calendar.strftime(@now, "%d %b %Y")} · UTC
              </p>
            </div><.link navigate={~p"/admin/users"}>All players ↗</.link>
          </div>
          <div class="desk-legend"><span>● Registered</span><span>● Guests</span></div>
          <svg
            class="desk-chart"
            viewBox="0 0 720 200"
            role="img"
            aria-labelledby="chart-title chart-desc"
          >
            <title id="chart-title">New accounts today by hour</title><desc id="chart-desc">
              {@new_accounts} new accounts today, including {@new_guests} guests. Hourly values are available in the data table below.
            </desc>
            <line x1="0" y1="170" x2="720" y2="170" />
            <g :for={bar <- @bars}>
              <title>
                {hour_label(bar.hour)} UTC: {bar.registered} registered, {bar.guests} guests
              </title>
              <rect
                class="desk-bar-registered"
                x={bar.hour * 30 + 5}
                y={170 - bar.total / @chart_max * 140}
                width="20"
                height={bar.registered / @chart_max * 140}
                rx="2"
              />
              <rect
                class="desk-bar-guest"
                x={bar.hour * 30 + 5}
                y={170 - bar.guests / @chart_max * 140}
                width="20"
                height={bar.guests / @chart_max * 140}
              />
              <text :if={rem(bar.hour, 3) == 0} x={bar.hour * 30 + 5} y="195">
                {hour_label(bar.hour)}
              </text>
            </g>
            <text x="0" y="16">Peak scale: {@chart_max} / hour</text>
          </svg>
          <p :if={@new_accounts == 0} class="desk-note">
            Waiting for the first arrival. New accounts will appear automatically.
          </p>
          <details class="desk-data">
            <summary>Hourly figures</summary><table>
              <thead>
                <tr>
                  <th>Hour UTC</th><th>Registered</th><th>Guests</th>
                </tr>
              </thead><tbody>
                <tr :for={bar <- @bars}>
                  <td>{hour_label(bar.hour)}</td><td>{bar.registered}</td><td>{bar.guests}</td>
                </tr>
              </tbody>
            </table>
          </details>
          <p class="desk-note">
            Account creation, including guests and returning Classic accounts. Not campaign attribution. Refreshes every 15 seconds.
          </p>
        </section>
        <section class="desk-roster" aria-labelledby="online-title">
          <div class="desk-heading">
            <h2 id="online-title">Here right now</h2><span class="desk-live-dot">● Live</span>
          </div>
          <div class="desk-breakdown">
            <span><b>{@breakdown[:playing] || 0}</b> playing</span><span><b>{@breakdown[:lobby] || 0}</b>
            in lobby</span><span><b>{@breakdown[:spectating] || 0}</b> watching</span>
          </div>
          <p :if={@roster == []} class="desk-empty">
            No players connected yet.<br />Keep this screen open to watch the room fill up.
          </p>
          <ul class="desk-people">
            <li :for={id <- @roster} id={"online-#{id}"}>
              <span class="desk-avatar">{String.first(player_name(@profiles[id]))}</span><div>
                <.link :if={@profiles[id]} navigate={~p"/admin/users/#{id}"}>{player_name(
                  @profiles[id]
                )}</.link><span :if={!@profiles[id]}>Player</span><small>{activity(@online[id])}</small>
              </div><span class="desk-presence" aria-label="Connected">●</span>
            </li>
          </ul>
          <p :if={map_size(@online) > 50} class="desk-note">
            Showing 50 of {map_size(@online)} connected players.
          </p>
        </section>
      </div>
      <div class="desk-bottom">
        <section aria-labelledby="tables-title">
          <div class="desk-heading">
            <div>
              <h2 id="tables-title">On the tables</h2><p>
                {@live_tables} attended · {@unattended} without connected humans
              </p>
            </div><.link navigate={~p"/admin/games"}>All games ↗</.link>
          </div>
          <p :if={@table_count == 0} class="desk-empty">
            No tables open. Games will appear here when players create them.
          </p>
          <div class="desk-tables">
            <.link
              :for={table <- @tables}
              navigate={~p"/admin/games/#{table.room.code}"}
              class={if table.humans > 0, do: "desk-table", else: "desk-table desk-unattended"}
            >
              <div>
                <strong>{table.room.config.name || table.room.code}</strong><span>{table.room.code} · {table.humans} humans connected</span>
              </div>
              <div>
                <b>{table_state(table)}</b><span :if={table.summary}>N/S {table.summary.cumulative_scores[
                  :north_south
                ] || 0} : {table.summary.cumulative_scores[:east_west] || 0} E/W</span>
              </div><span aria-hidden="true">↗</span>
            </.link>
          </div>
          <p :if={@table_count > 12} class="desk-note">
            Showing 12 of {@table_count} tables. Open all games for the full list.
          </p>
          <p :if={@unattended > 0} class="desk-note">
            Unattended tables stay visible for inspection and are excluded from the attended count.
          </p>
        </section>
        <section aria-labelledby="recent-title">
          <div class="desk-heading">
            <h2 id="recent-title">Latest arrivals</h2><span>Today · UTC</span>
          </div>
          <p :if={@recent == []} class="desk-empty">Today's newest players will appear here.</p>
          <ul class="desk-people">
            <li :for={user <- @recent}>
              <span class="desk-avatar">{String.first(User.public_name(user))}</span><div>
                <.link navigate={~p"/admin/users/#{user.id}"}>{User.public_name(user)}</.link><small>{if user.guest,
                  do: "Guest account",
                  else: "Registered account"}</small>
              </div><time>{Calendar.strftime(user.inserted_at, "%H:%M")}</time>
            </li>
          </ul>
        </section>
      </div>
    </.admin_shell>
    """
  end

  defp player_name(nil), do: "Player"
  defp player_name(user), do: User.public_name(user)
  defp activity(:playing), do: "Playing"
  defp activity(:spectating), do: "Watching a game"
  defp activity(_), do: "In the lobby"
  defp hour_label(hour), do: String.pad_leading(to_string(hour), 2, "0") <> ":00"
  defp table_state(%{humans: 0}), do: "Unattended"
  defp table_state(%{summary: nil, room: %{status: :playing}}), do: "Process unavailable"
  defp table_state(%{summary: nil}), do: "Waiting for players"
  defp table_state(%{summary: summary}), do: Phoenix.Naming.humanize(summary.phase)
end
