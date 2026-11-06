defmodule PidroServerWeb.Dev.GameListLive do
  @moduledoc "Admin-only, latest-state operational overview. Never subscribes to private game snapshots."
  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.Games.{AdminGameSummary, GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.Room.{Positions, Seat}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "admin:connections")
      Process.send_after(self(), :sample, 750)
    end

    {:ok,
     socket
     |> assign(:phase_filter, "all")
     |> assign(:sort_order, :desc)
     |> assign(:all_rooms, %{})
     |> assign(:summaries, %{})
     |> assign(:profiles, %{})
     |> assign(:changed, MapSet.new())
     |> assign(:now, DateTime.utc_now())
     |> assign(:developer_controls_open, false)
     |> assign(:show_create_form, false)
     |> assign(:delete_code, nil)
     |> assign(:page_title, "Live games")
     |> replace_rooms(RoomManager.list_rooms(:all))}
  end

  @impl true
  def handle_info(:sample, socket) do
    # Schedule AFTER processing: only one sampling message can be outstanding,
    # regardless of the number of actions or how slowly the browser consumes diffs.
    socket = sample(socket)
    Process.send_after(self(), :sample, 750)
    {:noreply, socket}
  end

  def handle_info({:room_updated, room}, socket) do
    previous = socket.assigns.all_rooms[room.code]

    fields = [
      :id,
      :status,
      :positions,
      :seats,
      :config,
      :pace,
      :host_id,
      :spectator_ids,
      :game_number
    ]

    # RoomManager also publishes hand/score changes on the lobby topic. Those
    # already live in the latest-only Registry projection; don't render per hand.
    if previous && Map.take(previous, fields) == Map.take(room, fields) do
      {:noreply, socket}
    else
      handle_info({:room_created, room}, socket)
    end
  end

  def handle_info({:room_created, room}, socket) do
    {:noreply,
     replace_rooms(socket, Map.put(socket.assigns.all_rooms, room.code, room) |> Map.values())}
  end

  def handle_info({:room_closed, code}, socket) do
    {:noreply, replace_rooms(socket, Map.delete(socket.assigns.all_rooms, code) |> Map.values())}
  end

  def handle_info({:lobby_update, _}, socket) do
    {:noreply, replace_rooms(socket, RoomManager.list_rooms(:all))}
  end

  def handle_info({:online_count_updated, _}, socket), do: {:noreply, socket}

  def handle_info({:connection_quality, code, seats}, socket) do
    case socket.assigns.all_rooms[code] do
      nil -> {:noreply, socket}
      room ->
        rooms = Map.put(socket.assigns.all_rooms, code, %{room | seats: seats})
        {:noreply, socket |> assign(:all_rooms, rooms) |> present()}
    end
  end

  def handle_info(message, socket) do
    PidroServer.Games.UnexpectedMessage.report_once(__MODULE__, message)
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_phase", %{"phase" => phase}, socket) do
    {:noreply, socket |> assign(:phase_filter, phase) |> present()}
  end

  def handle_event("toggle_sort", _, socket) do
    order = if socket.assigns.sort_order == :desc, do: :asc, else: :desc
    {:noreply, socket |> assign(:sort_order, order) |> present()}
  end

  def handle_event("toggle_developer_controls", _, socket) do
    {:noreply, assign(socket, :developer_controls_open, !socket.assigns.developer_controls_open)}
  end

  def handle_event("toggle_create_form", _, socket) do
    {:noreply, assign(socket, :show_create_form, !socket.assigns.show_create_form)}
  end

  def handle_event("cancel_create", _, socket),
    do: {:noreply, assign(socket, :show_create_form, false)}

  def handle_event("create_game", params, socket) do
    name = String.trim(Map.get(params, "game_name", ""))
    host = Map.get(params, "host_user_id", "dev_host")
    host = if host == "dev_host", do: name, else: host
    difficulty = Map.get(params, "bot_difficulty", "random")
    count = parse_bot_count(Map.get(params, "bot_count", "0"))

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Game name cannot be empty")}

      count not in 0..4 ->
        {:noreply, put_flash(socket, :error, "Choose between 0 and 4 bots")}

      true ->
        case RoomManager.create_room(host, %{name: name, bot_difficulty: difficulty}) do
          {:ok, room} ->
            result = start_bots(room.code, count, room.config.bot_difficulty)

            {:noreply,
             socket |> assign(:show_create_form, false) |> creation_flash(room.code, result)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not create room: #{inspect(reason)}")}
        end
    end
  end

  def handle_event(preset, _, socket)
      when preset in ~w(preset_empty_room preset_1h_3b preset_2h_2b preset_4_bots) do
    name = "Dev " <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    case RoomManager.create_room(name, %{name: name, bot_difficulty: :random, solo: false}) do
      {:ok, room} ->
        result =
          case preset do
            "preset_empty_room" ->
              :ok

            "preset_1h_3b" ->
              start_bots(room.code, 3, :random)

            "preset_2h_2b" ->
              start_bots_at_positions(room.code, [:east, :west])

            "preset_4_bots" ->
              RoomManager.dev_set_position(room.code, :north, nil)
              start_bots(room.code, 4, :random)
          end

        {:noreply,
         socket
         |> creation_flash(room.code, result)
         |> push_navigate(to: ~p"/admin/games/#{room.code}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create room: #{inspect(reason)}")}
    end
  end

  def handle_event("request_delete", %{"code" => code}, socket),
    do: {:noreply, assign(socket, :delete_code, code)}

  def handle_event("request_bulk_delete", _, socket),
    do: {:noreply, assign(socket, :delete_code, :finished)}

  def handle_event("cancel_confirm", _, socket), do: {:noreply, assign(socket, :delete_code, nil)}

  def handle_event("confirm_delete", _, %{assigns: %{delete_code: :finished}} = socket) do
    for room <- RoomManager.list_rooms(:all), room.status == :finished, do: delete_room(room.code)
    {:noreply, socket |> assign(:delete_code, nil) |> put_flash(:info, "Finished games deleted")}
  end

  def handle_event("confirm_delete", _, %{assigns: %{delete_code: code}} = socket)
      when is_binary(code) do
    result = delete_room(code)
    message = if result == :ok, do: "Game #{code} deleted", else: "Game #{code} no longer exists"
    {:noreply, socket |> assign(:delete_code, nil) |> put_flash(:info, message)}
  end

  def handle_event("confirm_delete", _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="games"
      title="Live games"
      class="admin-game-inspection"
      subtitle="Live tables · observation only until you choose an action"
      flash={@flash}
    >
      <:actions>
        <.link navigate={~p"/admin/game-settings"} class="text-sm underline">
          Game settings · bot base {Lifecycle.config(:bot_delay_ms)}ms
        </.link>
      </:actions>

      <div class="flex flex-wrap gap-3 text-sm" id="room-counts">
        <span><strong>{@stats.waiting}</strong> waiting</span>
        <span><strong>{@stats.playing}</strong> playing</span>
        <span><strong>{@stats.finished}</strong> finished</span>
        <span><strong>{@stats.issues}</strong> with connection / process issues</span>
      </div>
      <p class="text-xs text-stone-500">
        Elapsed time is informational. Own-pace tables may wait for human Continue; no inactivity alarm.
      </p>

      <div class="flex flex-wrap items-center gap-3">
        <form id="phase-filter-form" phx-change="filter_phase">
          <label for="phase-filter" class="text-sm">Phase</label>
          <select id="phase-filter" name="phase" class="rounded border-stone-300 text-sm">
            <option :for={{value, label} <- filters()} value={value} selected={@phase_filter == value}>
              {label}
            </option>
          </select>
        </form>
        <button phx-click="toggle_sort" class="rounded border border-stone-300 px-3 py-2 text-sm">
          {if @sort_order == :desc, do: "Newest First", else: "Oldest First"}
        </button>
        <span class="text-xs text-stone-500">Showing {length(@rooms)} of {map_size(@all_rooms)} games · sampled every 750ms</span>
      </div>

      <div id="game-rows" class="match-list">
        <div :if={@rooms != []} class="match-columns" aria-hidden="true">
          <span>Table / room</span><span>Players · teams</span><span>Game state</span><span>Activity · UTC</span><span>Actions</span>
        </div>
        <p :if={@rooms == []} class="rounded border border-dashed p-8 text-center text-stone-500">
          No active rooms at the moment
        </p>
        <article
          :for={room <- @rooms}
          id={"room-#{room.code}"}
          class={[
            "match-row",
            MapSet.member?(@changed, room.code) && "admin-row-changed"
          ]}
        >
          <% summary = @summaries[room.code] %>
          <div class="match-room">
            <.link
              navigate={~p"/admin/games/#{room.code}"}
              class="match-title"
            >{room.config.name || "Game #{room.code}"}</.link>
            <button
              id={"copy-#{room.code}"}
              phx-hook="Clipboard"
              data-clipboard-text={room.code}
              title="Copy room ID"
              class="match-code"
            ><.icon name="hero-square-2-stack" class="size-3.5" />{room.code}</button>
            <p :if={RoomManager.game_against_bots?(room)} class="mt-1 text-xs text-stone-500">
              vs bots
            </p>
            <details class="match-identifiers">
              <summary>Seat identifiers</summary>
              <ul>
                <li :for={{position, seat} <- room.seats} class="break-all">
                  {position} · {seat.user_id || "No player ID"}
                  <button
                    :if={seat.user_id}
                    id={"player-id-#{room.code}-#{position}"}
                    phx-hook="Clipboard"
                    data-clipboard-text={seat.user_id}
                    class="px-3 underline"
                    title={"Copy player ID: #{seat.user_id}"}
                  >Copy</button>
                </li>
              </ul>
            </details>
          </div>
          <.participant_teams seats={team_seats(room, @profiles, @now)} />
          <div class="match-state">
            <.match_status status={room.status} />
            <p class="mt-2 text-sm font-semibold">{phase_label(summary, room)}</p>
            <p class="match-score">
              N/S {score(summary, :north_south)} · E/W {score(summary, :east_west)}
            </p>
            <p :if={summary && summary.current_turn} class="mt-1 text-xs text-stone-600">
              Turn: {seat_name(
                room.seats[summary.current_turn],
                @profiles[room.seats[summary.current_turn].user_id]
              )} ({summary.current_turn})
            </p>
            <p class="mt-1 text-xs text-stone-500">
              Pace: {if summary, do: summary.pace, else: room.pace}
            </p>
          </div>
          <div class="match-time">
            <%= if summary do %>
              <p>{humanize(summary.last_event)}</p>
              <time
                datetime={DateTime.to_iso8601(summary.updated_at)}
                title={DateTime.to_iso8601(summary.updated_at)}
              >{elapsed(summary.updated_at, @now)} ago</time>
            <% else %>
              <p>
                {if room.status == :playing,
                  do: "Game process unavailable",
                  else: "Waiting for players"}
              </p>
            <% end %>
            <p class="mt-1">{Positions.count(room)} / 4 seated</p>
            <p :if={is_nil(room.host_id)} class="mt-1">No owner</p>
            <p :if={issue?(room, summary)} class="mt-1 text-amber-700">
              Connection / process issue
            </p>
            <p :if={Enum.any?(room.seats, fn {_, seat} -> away?(seat) end)} class="mt-1">
              Player away
            </p>
            <p class="mt-2">Created {Calendar.strftime(room.created_at, "%d %b %H:%M UTC")}</p>
          </div>
          <div class="match-actions">
            <.link navigate={~p"/admin/games/#{room.code}"} class="match-primary">
              <.icon name="hero-eye" class="size-4" />Watch
            </.link>
            <button phx-click="request_delete" phx-value-code={room.code} class="match-delete">
              <.icon name="hero-trash" class="size-4" />Delete
            </button>
          </div>
        </article>
      </div>

      <details
        id="developer-controls"
        open={@show_create_form || @developer_controls_open}
        class="rounded-lg border border-stone-200 bg-white p-4"
      >
        <summary phx-click="toggle_developer_controls" class="cursor-pointer text-sm font-medium">
          Developer controls · create a game
        </summary>
        <div class="mt-4 flex flex-wrap gap-2">
          <button
            :for={
              {event, label} <- [
                {"preset_empty_room", "Empty Room"},
                {"preset_1h_3b", "1H + 3B"},
                {"preset_2h_2b", "2H + 2B"},
                {"preset_4_bots", "4 Bots"}
              ]
            }
            phx-click={event}
            class="rounded border px-3 py-2 text-sm"
          >{label}</button>
          <button phx-click="toggle_create_form" class="rounded border px-3 py-2 text-sm">New Game</button>
          <button
            :if={@stats.finished > 0}
            phx-click="request_bulk_delete"
            class="rounded border px-3 py-2 text-sm text-red-700"
          >Delete All Finished ({@stats.finished})</button>
        </div>
        <form
          :if={@show_create_form}
          id="create-game-form"
          phx-submit="create_game"
          class="mt-4 grid gap-3 sm:grid-cols-2"
        >
          <label class="text-sm">Game name<input
            name="game_name"
            required
            class="block w-full rounded border-stone-300"
          /></label>
          <label class="text-sm">Host ID (or dev_host)<input
            name="host_user_id"
            value="dev_host"
            class="block w-full rounded border-stone-300"
          /></label>
          <label class="text-sm">Bots<input
            name="bot_count"
            type="number"
            min="0"
            max="4"
            value="0"
            class="block w-full rounded border-stone-300"
          /></label>
          <label class="text-sm">Difficulty<select
            name="bot_difficulty"
            class="block w-full rounded border-stone-300"
          ><option value="random">random</option><option value="basic">basic</option><option value="smart">
            smart
          </option></select></label>
          <button class="rounded bg-stone-900 px-3 py-2 text-white">Create</button>
          <button type="button" phx-click="cancel_create">Cancel</button>
        </form>
      </details>

      <div
        :if={@delete_code}
        role="dialog"
        aria-modal="true"
        aria-label="Confirm Delete"
        class="fixed inset-0 z-50 grid place-items-center bg-stone-950/40 p-4"
      >
        <div class="rounded-lg bg-white p-6">
          <p>
            {if @delete_code == :finished,
              do: "Delete all finished games?",
              else: "Delete game #{@delete_code}?"}
          </p>
          <div class="mt-4 flex gap-4">
            <button phx-click="confirm_delete" class="text-red-700">Confirm</button><button phx-click="cancel_confirm">Cancel</button>
          </div>
        </div>
      </div>
    </.admin_shell>
    """
  end

  defp replace_rooms(socket, rooms) do
    ids = rooms |> Enum.flat_map(&Positions.player_ids/1) |> Enum.uniq()
    # Only membership changes query the DB, in one batch, never per seat/action.
    old_ids = socket.assigns.profiles |> Map.keys() |> Enum.sort()

    profiles =
      if Enum.sort(ids) == old_ids, do: socket.assigns.profiles, else: public_profiles(ids)

    socket
    |> assign(:all_rooms, Map.new(rooms, &{&1.code, &1}))
    |> assign(:profiles, profiles)
    |> sample()
  end

  defp public_profiles(ids) do
    # Developer hosts may be arbitrary strings, including 16-byte strings that
    # UUID.cast accepts as raw UUIDs but UUID.dump cannot send to the database.
    users = ids |> Enum.filter(&match?({:ok, _}, Ecto.UUID.dump(&1))) |> Auth.get_users_map()

    Map.new(ids, fn id ->
      user = users[id]
      {id, if(user, do: %{name: User.public_name(user), avatar_url: user.avatar_url})}
    end)
  end

  defp sample(socket) do
    summaries =
      Map.new(socket.assigns.all_rooms, fn {code, _} -> {code, AdminGameSummary.get(code)} end)

    changed =
      for {code, summary} <- summaries,
          summary != socket.assigns.summaries[code],
          into: MapSet.new(),
          do: code

    socket
    |> assign(:summaries, summaries)
    |> assign(:changed, changed)
    |> assign(:now, DateTime.utc_now())
    |> present()
  end

  defp present(socket) do
    rooms = Map.values(socket.assigns.all_rooms)
    summaries = socket.assigns.summaries
    filter = socket.assigns.phase_filter

    visible =
      Enum.filter(rooms, fn room ->
        summary = summaries[room.code]

        filter == "all" or filter == to_string(room.status) or
          (filter == "waiting" and room.status == :ready) or
          (not is_nil(summary) and filter == to_string(summary.phase)) or
          (filter == "issues" and issue?(room, summary))
      end)

    stats = %{
      waiting: Enum.count(rooms, &(&1.status in [:waiting, :ready])),
      playing: Enum.count(rooms, &(&1.status == :playing)),
      finished: Enum.count(rooms, &(&1.status == :finished)),
      issues: Enum.count(rooms, &issue?(&1, summaries[&1.code]))
    }

    socket
    |> assign(
      :rooms,
      Enum.sort_by(visible, & &1.created_at, {socket.assigns.sort_order, DateTime})
    )
    |> assign(:stats, stats)
  end

  defp issue?(room, summary) do
    (room.status == :playing and is_nil(summary)) or
      Enum.any?(room.seats, fn {_, seat} ->
        (seat.status in [:reconnecting, :grace] or
           (seat.status == :bot_substitute and not is_nil(seat.reserved_for))) and
          not away?(seat)
      end)
  end

  defp away?(%{occupant_type: :human, status: status, disconnected_at: %DateTime{}})
       when status in [:reconnecting, :grace], do: true

  defp away?(%{status: :bot_substitute, reserved_for: id, disconnected_at: %DateTime{}})
       when is_binary(id), do: true

  defp away?(_seat), do: false

  defp team_seats(room, profiles, now) do
    Map.new(room.seats, fn {position, seat} ->
      bot = if seat.occupant_type == :bot, do: PidroServer.BotCatalogue.profile(seat.bot_persona)

      avatar =
        cond do
          bot -> PidroServer.BotCatalogue.avatar_url(bot)
          seat.occupant_type == :human -> get_in(profiles, [seat.user_id, :avatar_url])
          true -> nil
        end

      {position,
       %{
         name: seat_name(seat, profiles[seat.user_id]),
         detail: connection(seat, room, now),
         kind: seat.occupant_type,
         quality: if(seat.user_id || seat.reserved_for, do: PidroServer.Stats.summarize_connections(List.wrap(Seat.connection_totals(seat)))),
         avatar_url: avatar
       }}
    end)
  end

  defp seat_name(%{bot_persona: persona}, _) when is_binary(persona),
    do: Seat.bot_display_name(persona)

  defp seat_name(%{occupant_type: :bot}, _), do: "Bot"
  defp seat_name(_, %{name: name}), do: name
  defp seat_name(%{occupant_type: :vacant}, _), do: "Open seat"
  defp seat_name(_, _), do: "Unknown player"

  defp connection(%{occupant_type: :vacant}, _room, _now), do: ""
  defp connection(%{occupant_type: :bot, status: :connected}, _room, _now), do: "bot"

  defp connection(seat, room, now) do
    if away?(seat) do
      elapsed_ms = max(0, DateTime.diff(now, seat.disconnected_at, :millisecond))
      label = "Away #{div(elapsed_ms, 60_000)}m"

      if room.status == :playing and RoomManager.game_against_bots?(room) do
        remaining = max(0, Lifecycle.config(:solo_absence_timeout_ms) - elapsed_ms)
        label <> " · closes in #{ceil(remaining / 60_000)}m"
      else
        label
      end
    else
      humanize(seat.status)
    end
  end

  defp score(nil, _), do: "–"
  defp score(summary, team), do: summary.cumulative_scores[team] || 0
  defp phase_label(nil, room), do: humanize(room.status)
  defp phase_label(%{phase: :hand_complete}, _), do: "Waiting for Continue"
  defp phase_label(%{phase: :playing, trick_number: trick}, _), do: "Playing · trick #{trick}"
  defp phase_label(summary, _), do: humanize(summary.phase)
  defp humanize(nil), do: ""

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp elapsed(time, now) do
    seconds = max(DateTime.diff(now, time), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  defp filters,
    do: [
      {"all", "All"},
      {"waiting", "Waiting"},
      {"playing", "Playing"},
      {"bidding", "Bidding"},
      {"declaring", "Declaring trump"},
      {"dealer_selection", "Dealer selection"},
      {"hand_complete", "Waiting for Continue"},
      {"finished", "Finished"},
      {"issues", "Connection / process issues"}
    ]

  defp start_bots(_, 0, _), do: :ok

  defp start_bots(code, count, strategy) do
    BotManager.start_bots(code, count, strategy)
  catch
    :exit, _ -> {:error, :bot_manager_unavailable}
  end

  defp start_bots_at_positions(code, positions) do
    Enum.reduce_while(positions, :ok, fn position, :ok ->
      case BotManager.start_bot(code, position, :random) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  catch
    :exit, _ -> {:error, :bot_manager_unavailable}
  end

  defp creation_flash(socket, code, {:error, _}) do
    # A failed start can mean the manager itself is down. Cleanup is best-effort;
    # keep the successfully created room and let the admin retry later.
    try do
      BotManager.stop_all_bots(code)
    catch
      :exit, _ -> :ok
    end

    put_flash(socket, :warning, "Room #{code} created, but bots could not be started")
  end

  defp creation_flash(socket, code, _), do: put_flash(socket, :info, "Created #{code}")

  defp parse_bot_count(value) do
    case Integer.parse(value) do
      {count, ""} -> count
      _ -> -1
    end
  end

  defp delete_room(code) do
    BotManager.stop_all_bots(code)
    GameSupervisor.stop_game(code)
    RoomManager.close_room(code)
  end
end
