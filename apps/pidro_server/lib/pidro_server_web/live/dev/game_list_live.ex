defmodule PidroServerWeb.Dev.GameListLive do
  @moduledoc """
  Admin-only, latest-state view of every open table, drawn as a small felt.

  Never subscribes to private game snapshots: it samples the public table
  projection in `AdminGameSummary` (cards on the felt, bids, trump, dealer,
  scores, card counts) and lobby lifecycle PubSub. No card in a hand is shown.
  """
  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Accounts.{Auth, User}
  alias PidroServer.BotCatalogue
  alias PidroServer.Games.{AdminGameSummary, GameSupervisor, Lifecycle, RoomManager}
  alias PidroServer.Games.Bots.BotManager
  alias PidroServer.Games.Room.{Positions, Seat}
  alias PidroServer.{Profiles, Stats}
  alias PidroServer.Rating.Tier
  alias PidroServerWeb.CardHelpers

  @positions [:north, :east, :south, :west]
  @winning_score 62
  @tricks_per_hand 6

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
     |> assign(:preview, nil)
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

  def handle_event("preview", %{"code" => code, "position" => position}, socket) do
    open = socket.assigns.preview

    if open && open.code == code && to_string(open.position) == position do
      {:noreply, assign(socket, :preview, nil)}
    else
      {:noreply, assign(socket, :preview, load_preview(socket.assigns.all_rooms[code], position))}
    end
  end

  def handle_event("close_preview", _, socket), do: {:noreply, assign(socket, :preview, nil)}

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
      class="live-tables"
      flash={@flash}
    >
      <:actions>
        <.link navigate={~p"/admin/game-settings"} class="lt-settings-link">
          <.icon name="hero-adjustments-horizontal" class="size-4" />
          Game settings · bots every {seconds(Lifecycle.config(:bot_delay_ms))}
        </.link>
      </:actions>

      <div class="lt-toolbar">
        <form id="phase-filter-form" phx-change="filter_phase" class="lt-filters" role="radiogroup" aria-label="Show tables">
          <label
            :for={{value, label, count} <- filter_chips(@stats)}
            class={["lt-filter", value == "issues" && count > 0 && "lt-filter-alert"]}
          >
            <input type="radio" name="phase" value={value} checked={@phase_filter == value} class="sr-only" />
            <span>{label}</span>
            <span class="lt-filter-count">{count}</span>
          </label>
        </form>
        <div id="room-counts" class="sr-only">
          {@stats.waiting} waiting, {@stats.playing} playing, {@stats.finished} finished
        </div>
        <div class="lt-toolbar-end">
          <span class="lt-live" title="Tables refresh every 750ms"><span class="lt-live-dot"></span>Live</span>
          <button phx-click="toggle_sort" class="lt-sort">
            <.icon
              name={if @sort_order == :desc, do: "hero-bars-arrow-down", else: "hero-bars-arrow-up"}
              class="size-4"
            />
            {if @sort_order == :desc, do: "Newest first", else: "Oldest first"}
          </button>
        </div>
      </div>

      <div :if={@tiles == []} class="lt-empty">
        <div class="lt-empty-felt" aria-hidden="true">
          <span :for={_ <- 1..4} class="lt-empty-seat"></span>
        </div>
        <p class="lt-empty-title">
          {if map_size(@all_rooms) == 0, do: "No tables open", else: "No tables match this filter"}
        </p>
        <p class="lt-empty-body">
          {if map_size(@all_rooms) == 0,
            do: "Tables appear here the moment someone creates a game. Developer controls below can start a bot table.",
            else: "Pick All to see every open table."}
        </p>
      </div>

      <div id="game-rows" class="lt-grid">
        <.table_tile :for={tile <- @tiles} tile={tile} preview={@preview} />
      </div>

      <details
        id="developer-controls"
        open={@show_create_form || @developer_controls_open}
        class="lt-dev"
      >
        <summary phx-click="toggle_developer_controls">
          <.icon name="hero-wrench-screwdriver" class="size-4" /> Developer controls · create a game
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
            class="lt-button"
          >{label}</button>
          <button phx-click="toggle_create_form" class="lt-button">New Game</button>
          <button
            :if={@stats.finished > 0}
            phx-click="request_bulk_delete"
            class="lt-button text-red-700"
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
            class="mt-1 block w-full rounded-md border border-stone-300 bg-white px-3 py-2"
          /></label>
          <label class="text-sm">Host ID (or dev_host)<input
            name="host_user_id"
            value="dev_host"
            class="mt-1 block w-full rounded-md border border-stone-300 bg-white px-3 py-2"
          /></label>
          <label class="text-sm">Bots<input
            name="bot_count"
            type="number"
            min="0"
            max="4"
            value="0"
            class="mt-1 block w-full rounded-md border border-stone-300 bg-white px-3 py-2"
          /></label>
          <label class="text-sm">Difficulty<select
            name="bot_difficulty"
            class="mt-1 block w-full rounded-md border border-stone-300 bg-white px-3 py-2"
          ><option value="random">random</option><option value="basic">basic</option><option value="smart">
            smart
          </option></select></label>
          <button class="lt-button lt-button-dark">Create</button>
          <button type="button" class="lt-button" phx-click="cancel_create">Cancel</button>
        </form>
      </details>

      <div
        :if={@delete_code}
        role="dialog"
        aria-modal="true"
        aria-label="Confirm Delete"
        class="fixed inset-0 z-50 grid place-items-center bg-stone-950/40 p-4"
      >
        <div class="lt-confirm" phx-click-away="cancel_confirm" phx-window-keydown="cancel_confirm" phx-key="Escape">
          <p class="font-semibold">
            {if @delete_code == :finished,
              do: "Delete all finished games?",
              else: "Delete game #{@delete_code}?"}
          </p>
          <p class="mt-1 text-sm text-stone-600">Bots stop and anyone seated is sent back to the lobby.</p>
          <div class="mt-5 flex justify-end gap-2">
            <button phx-click="cancel_confirm" class="lt-button">Cancel</button>
            <button phx-click="confirm_delete" class="lt-button lt-button-danger">Confirm</button>
          </div>
        </div>
      </div>
    </.admin_shell>
    """
  end

  # ---------------------------------------------------------------------------
  # Table tile
  # ---------------------------------------------------------------------------

  attr :tile, :map, required: true
  attr :preview, :map, default: nil

  defp table_tile(assigns) do
    ~H"""
    <article
      id={"room-#{@tile.code}"}
      class={[
        "lt-tile",
        "lt-phase-#{@tile.stage}",
        @tile.issue && "lt-tile-issue",
        @preview && @preview.code == @tile.code && "lt-tile-raised"
      ]}
    >
      <header class="lt-head">
        <div class="lt-title-row">
          <.link navigate={~p"/admin/games/#{@tile.code}"} class="lt-title">{@tile.name}</.link>
          <button
            id={"copy-#{@tile.code}"}
            phx-hook="Clipboard"
            data-clipboard-text={@tile.code}
            title={"Copy room ID · created #{@tile.created}"}
            class="lt-code"
          >{@tile.code}</button>
        </div>
        <div class="lt-head-end">
          <span :if={@tile.vs_bots} class="lt-tag">vs bots</span>
          <span :if={@tile.own_pace} class="lt-tag" title="Own pace: players press Continue between hands">own pace</span>
          <span class={["lt-phase", "lt-phase-pill-#{@tile.stage}"]}>
            <span :if={@tile.stage == :live} class="lt-phase-dot"></span>{@tile.phase_label}
          </span>
        </div>
      </header>

      <div class="lt-felt">
        <div class="lt-corner lt-corner-tl">
          <span :if={@tile.trump} class={["lt-trump", red?(@tile.trump) && "lt-red"]} title={"Trump: #{@tile.trump}"}>
            {CardHelpers.suit_symbol(@tile.trump)}
          </span>
        </div>
        <div class="lt-corner lt-corner-tr">
          <span :if={@tile.bid} class={["lt-bid-chip", "lt-team-#{@tile.bid.team}"]} title={"#{@tile.bid.name} bid #{@tile.bid.amount}"}>
            <span class="lt-bid-chip-label">Bid</span>{@tile.bid.amount}
          </span>
        </div>
        <div class="lt-corner lt-corner-bl">
          <span :if={@tile.hand_number} class="lt-hand-no">Hand {@tile.hand_number}</span>
        </div>
        <div class="lt-corner lt-corner-br">
          <span :if={@tile.trick_pips} class="lt-pips" title={"Trick #{@tile.trick_pips.current} of #{@tile.trick_pips.total}"}>
            <span
              :for={n <- 1..@tile.trick_pips.total}
              class={[
                "lt-pip",
                n < @tile.trick_pips.current && "lt-pip-done",
                n == @tile.trick_pips.current && "lt-pip-now"
              ]}
            ></span>
          </span>
        </div>

        <.seat :for={seat <- @tile.seats} seat={seat} code={@tile.code} preview={@preview} />

        <div class="lt-center">
          <%= case @tile.center do %>
            <% {:trick, trick} -> %>
              <div
                :for={{position, card} <- trick.plays}
                id={"card-#{@tile.code}-#{@tile.hand_number}-#{trick.number}-#{position}"}
                class={[
                  "lt-card",
                  "lt-card-#{position}",
                  red?(card) && "lt-red",
                  trick.winner && trick.winner != position && "lt-card-beaten",
                  trick.winner == position && "lt-card-won"
                ]}
                title={CardHelpers.format_card(card)}
              >
                <span class="lt-card-rank">{CardHelpers.format_rank(elem(card, 0))}</span>
                <span class="lt-card-suit">{CardHelpers.suit_symbol(elem(card, 1))}</span>
                <span :if={points(card, @tile.trump) > 0} class="lt-card-points">{points(card, @tile.trump)}</span>
                <span :if={trick.winner == position && trick.points > 0} class="lt-trick-take">+{trick.points}</span>
              </div>
            <% {:bidding, nil} -> %>
              <p class="lt-center-note">Bidding</p>
            <% {:bidding, bid} -> %>
              <p class="lt-center-big" id={"high-#{@tile.code}-#{bid.amount}"}>{bid.amount}</p>
              <p class="lt-center-note">High bid · {bid.name}</p>
            <% {:declaring, bid} -> %>
              <p class="lt-center-suits" aria-hidden="true"><span>♠</span><span class="lt-red">♥</span><span>♣</span><span class="lt-red">♦</span></p>
              <p class="lt-center-note">{bid && bid.name} picks trump</p>
            <% {:dealing, label} -> %>
              <div class="lt-deck" aria-hidden="true"><span></span><span></span><span></span></div>
              <p class="lt-center-note">{label}</p>
            <% {:hand_done, hand} -> %>
              <p class="lt-hand-result">
                <span class="lt-team-text-north_south">{signed(hand.north_south)}</span>
                <span class="lt-hand-result-sep">·</span>
                <span class="lt-team-text-east_west">{signed(hand.east_west)}</span>
              </p>
              <p class="lt-center-note">{if @tile.own_pace, do: "Waiting for Continue", else: "Hand scored"}</p>
            <% {:finished, winner} -> %>
              <.icon name="hero-trophy" class="lt-trophy" />
              <p class="lt-center-note">{winner || "Game over"}</p>
            <% {:waiting, seated} -> %>
              <p class="lt-center-big lt-center-dim">{seated}<span>/4</span></p>
              <p class="lt-center-note">{if seated == 4, do: "Ready to deal", else: "Waiting for players"}</p>
            <% {:missing, _} -> %>
              <.icon name="hero-exclamation-triangle" class="lt-trophy lt-warn" />
              <p class="lt-center-note">Game process unavailable</p>
          <% end %>
        </div>
      </div>

      <div class="lt-teams">
        <div :for={team <- @tile.teams} class={["lt-team", "lt-team-#{team.key}", team.leading && "lt-team-leading"]} data-score={team.key}>
          <div class="lt-team-line">
            <span class="lt-team-swatch" aria-hidden="true"></span>
            <span class="lt-team-names" title={team.names}>{team.names}</span>
            <span :if={team.hand_points} class="lt-team-hand" title="Points this hand">+{team.hand_points}</span>
            <span class="lt-team-score">{team.score}</span>
          </div>
          <div class="lt-team-bar" aria-hidden="true">
            <span style={"transform: scaleX(#{team.progress})"}></span>
          </div>
        </div>
      </div>

      <footer class="lt-foot">
        <p class="lt-activity">
          <%= cond do %>
            <% @tile.issue -> %>
              <span class="lt-alert"><.icon name="hero-exclamation-triangle-mini" class="size-4" />Connection / process issue</span>
            <% @tile.away -> %>
              <span class="lt-away-note"><.icon name="hero-moon-mini" class="size-4" />Player away</span>
            <% @tile.no_owner -> %>
              <span>No owner</span>
            <% true -> %>
          <% end %>
          <span :if={@tile.last_event} class="lt-event">{@tile.last_event}</span>
          <time :if={@tile.updated_at} datetime={DateTime.to_iso8601(@tile.updated_at)} title={DateTime.to_iso8601(@tile.updated_at)}>{@tile.elapsed}</time>
          <span :if={!@tile.updated_at} class="lt-event">Opened {@tile.opened}</span>
          <span :if={@tile.no_owner && (@tile.issue || @tile.away)} class="sr-only">No owner</span>
        </p>
        <div class="lt-actions">
          <button
            phx-click="request_delete"
            phx-value-code={@tile.code}
            class="lt-icon-button"
            title="Delete game"
          ><.icon name="hero-trash" class="size-4" /><span class="sr-only">Delete</span></button>
          <.link navigate={~p"/admin/games/#{@tile.code}"} class="lt-watch">
            <.icon name="hero-eye-mini" class="size-4" />Watch
          </.link>
        </div>
      </footer>
    </article>
    """
  end

  attr :seat, :map, required: true
  attr :code, :string, required: true
  attr :preview, :map, default: nil

  defp seat(assigns) do
    assigns =
      assign(
        assigns,
        :open,
        assigns.preview && assigns.preview.code == assigns.code &&
          assigns.preview.position == assigns.seat.position
      )

    ~H"""
    <div
      class={[
        "lt-seat",
        "lt-seat-#{@seat.position}",
        "lt-team-#{@seat.team}",
        @seat.kind == :vacant && "lt-seat-open",
        @seat.turn && "lt-seat-turn",
        @seat.cold && "lt-seat-cold",
        @seat.away && "lt-seat-away"
      ]}
      phx-click-away={@open && "close_preview"}
    >
      <button
        :if={@seat.kind != :vacant}
        type="button"
        class="lt-seat-button"
        phx-click="preview"
        phx-value-code={@code}
        phx-value-position={@seat.position}
        aria-expanded={to_string(!!@open)}
        data-seat-preview
      >
        <.avatar seat={@seat} />
        <span class="lt-seat-name"><span
            :if={@seat.quality && @seat.quality.grade != :insufficient}
            class={["lt-net", "lt-net-#{@seat.quality.grade}"]}
            title={connection_label(@seat.quality)}
            aria-label={"Connection: #{@seat.quality.grade}"}
          ></span>{@seat.name}</span>
      </button>
      <div :if={@seat.kind == :vacant} class="lt-seat-button">
        <span class="lt-avatar lt-avatar-open" aria-hidden="true"><.icon name="hero-plus-mini" class="size-4" /></span>
        <span class="lt-seat-name">Open</span>
      </div>
      <span :if={@seat.turn} class="sr-only">Turn: {@seat.name} ({@seat.position})</span>
      <span :if={@seat.detail} class={["lt-seat-detail", @seat.away && "lt-seat-detail-away"]}>{@seat.detail}</span>
      <span :if={@seat.cards_left} class="lt-backs" aria-label={"#{@seat.cards_left} cards in hand"}>
        <span :for={_ <- 1..@seat.cards_left//1} class="lt-back"></span>
      </span>
      <.preview_card :if={@open} preview={@preview} />
    </div>
    """
  end

  attr :seat, :map, required: true
  attr :size, :string, default: "md"

  defp avatar(assigns) do
    ~H"""
    <span class={["lt-avatar", "lt-avatar-#{@size}", "lt-avatar-#{@seat.kind}"]}>
      <span class="lt-avatar-face">
        <span class="lt-avatar-initial" aria-hidden="true">{@seat.initial}</span>
        <img :if={@seat.avatar_url} src={@seat.avatar_url} alt="" loading="lazy" onerror="this.hidden=true" />
      </span>
      <span :if={@seat[:dealer]} class="lt-badge lt-badge-dealer" title="Dealer">D</span>
      <span :if={@seat.kind == :bot} class="lt-badge lt-badge-bot" title="Bot">
        <.icon name="hero-cpu-chip-micro" class="size-2.5" />
      </span>
      <span :if={@seat[:away]} class="lt-badge lt-badge-away" title="Away"></span>
      <span
        :if={@seat[:bid]}
        id={"bid-#{@seat[:bid_key]}"}
        class={["lt-badge lt-badge-bid", @seat.bid == :pass && "lt-badge-pass"]}
      >{if @seat.bid == :pass, do: "–", else: @seat.bid}</span>
    </span>
    """
  end

  attr :preview, :map, required: true

  defp preview_card(assigns) do
    ~H"""
    <div
      id={"preview-#{@preview.code}-#{@preview.position}"}
      class={["lt-preview", "lt-preview-from-#{@preview.position}"]}
      role="dialog"
      aria-label={"#{@preview.name} preview"}
      phx-window-keydown="close_preview"
      phx-key="Escape"
    >
      <div class="lt-preview-head">
        <.avatar seat={@preview} size="lg" />
        <div class="min-w-0">
          <p class="lt-preview-name">{@preview.name}</p>
          <p class="lt-preview-sub">
            <%= if @preview.kind == :bot do %>
              Bot · {@preview.strategy}
            <% else %>
              {@preview.level}{if @preview.title, do: " · #{@preview.title}"}
            <% end %>
          </p>
          <p :if={@preview.kind == :human} class="lt-preview-tags">
            <span :if={@preview.pin == "classic"} class="lt-chip lt-chip-gold">Classic</span>
            <span :if={@preview.guest} class="lt-chip">Guest</span>
            <span :if={@preview.registered} class="lt-chip">{@preview.tier}</span>
          </p>
        </div>
      </div>

      <%= if @preview.kind == :human do %>
        <dl :if={@preview.registered} class="lt-preview-stats">
          <div><dt>Games</dt><dd>{@preview.games}</dd></div>
          <div><dt>Won</dt><dd>{@preview.win_rate}</dd></div>
          <div><dt>Quit</dt><dd class={@preview.abandoned > 0 && "lt-warn"}>{@preview.abandoned}</dd></div>
        </dl>
        <p :if={!@preview.registered} class="lt-preview-id">{@preview.user_id}</p>
        <p :if={@preview.quality} class="lt-preview-net">
          <span class={["lt-net", "lt-net-#{@preview.quality.grade}"]}></span>{connection_label(@preview.quality)}
        </p>
        <p class="lt-preview-meta">
          <span>{@preview.connection}</span>
          <span :if={@preview.joined}>Joined {@preview.joined}</span>
        </p>
        <div class="lt-preview-actions">
          <button
            id={"copy-player-#{@preview.code}-#{@preview.position}"}
            phx-hook="Clipboard"
            data-clipboard-text={@preview.user_id}
            class="lt-button"
            title={@preview.user_id}
          ><.icon name="hero-square-2-stack-mini" class="size-4" />Copy ID</button>
          <.link
            :if={@preview.registered}
            navigate={~p"/admin/users/#{@preview.user_id}"}
            class="lt-button lt-button-dark"
          >
            Open profile <.icon name="hero-arrow-right-mini" class="size-4" />
          </.link>
        </div>
      <% else %>
        <p :if={@preview.description not in [nil, ""]} class="lt-preview-desc">{@preview.description}</p>
        <p :if={@preview.connection} class="lt-preview-meta"><span>{@preview.connection}</span></p>
        <div class="lt-preview-actions">
          <.link navigate={~p"/admin/bots"} class="lt-button">
            Bot catalogue <.icon name="hero-arrow-right-mini" class="size-4" />
          </.link>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Sampling
  # ---------------------------------------------------------------------------

  defp replace_rooms(socket, rooms) do
    ids = rooms |> Enum.flat_map(&Positions.player_ids/1) |> Enum.uniq()
    # Only membership changes query the DB, in one batch, never per seat/action.
    old_ids = socket.assigns.profiles |> Map.keys() |> Enum.sort()

    profiles =
      if Enum.sort(ids) == old_ids, do: socket.assigns.profiles, else: public_profiles(ids)

    preview = socket.assigns.preview

    socket
    |> assign(:all_rooms, Map.new(rooms, &{&1.code, &1}))
    |> assign(:profiles, profiles)
    |> assign(:preview, if(preview && Enum.any?(rooms, &(&1.code == preview.code)), do: preview))
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

    socket
    |> assign(:summaries, summaries)
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
      all: length(rooms),
      waiting: Enum.count(rooms, &(&1.status in [:waiting, :ready])),
      playing: Enum.count(rooms, &(&1.status == :playing)),
      hand_complete:
        Enum.count(rooms, &match?(%{phase: :hand_complete}, summaries[&1.code])),
      finished: Enum.count(rooms, &(&1.status == :finished)),
      issues: Enum.count(rooms, &issue?(&1, summaries[&1.code]))
    }

    %{profiles: profiles, now: now} = socket.assigns

    tiles =
      visible
      |> Enum.sort_by(& &1.created_at, {socket.assigns.sort_order, DateTime})
      |> Enum.map(&tile(&1, summaries[&1.code], profiles, now))

    socket
    |> assign(:tiles, tiles)
    |> assign(:stats, stats)
  end

  defp filter_chips(stats) do
    [
      {"all", "All", stats.all},
      {"playing", "Playing", stats.playing},
      {"waiting", "Waiting", stats.waiting},
      {"hand_complete", "Holding", stats.hand_complete},
      {"finished", "Finished", stats.finished},
      {"issues", "Issues", stats.issues}
    ]
  end

  # ---------------------------------------------------------------------------
  # Tile view model
  # ---------------------------------------------------------------------------

  defp tile(room, summary, profiles, now) do
    table = summary && summary[:table]
    bid = table && table.bid && bid_view(room, profiles, table.bid)
    stage = stage(room, summary)

    seats =
      Enum.map(@positions, fn position ->
        seat_view(room, position, profiles, now, summary, table)
      end)

    %{
      code: room.code,
      name: room.config.name || "Game #{room.code}",
      created: Calendar.strftime(room.created_at, "%d %b %H:%M UTC"),
      stage: stage,
      phase_label: phase_label(summary, room),
      vs_bots: RoomManager.game_against_bots?(room),
      own_pace: (summary && summary.pace || room.pace) == :own,
      issue: issue?(room, summary),
      away: Enum.any?(room.seats, fn {_, seat} -> away?(seat) end),
      no_owner: is_nil(room.host_id),
      trump: table && table.trump,
      bid: if(summary && summary.phase not in [:bidding], do: bid),
      hand_number: summary && summary.phase not in [:dealer_selection] && summary.hand_number,
      trick_pips: trick_pips(summary, table),
      seats: seats,
      center: center(room, summary, table, bid, seats),
      teams: teams(room, summary, table, seats),
      last_event: summary && humanize(summary.last_event),
      updated_at: summary && summary.updated_at,
      elapsed: summary && elapsed(summary.updated_at, now),
      opened: "#{elapsed(room.created_at, now)} ago"
    }
  end

  defp stage(%{status: :finished}, _), do: :finished
  defp stage(%{status: :playing}, nil), do: :issue
  defp stage(%{status: :playing}, %{phase: :hand_complete}), do: :hold
  defp stage(%{status: :playing}, _), do: :live
  defp stage(_, _), do: :waiting

  defp seat_view(room, position, profiles, now, summary, table) do
    seat = room.seats[position]
    profile = profiles[seat.user_id]
    bot = if seat.occupant_type == :bot, do: BotCatalogue.profile(seat.bot_persona)
    name = seat_name(seat, profile)
    phase = summary && summary.phase
    live? = room.status == :playing and not is_nil(summary)
    bid = table && Map.get(table.bids, position)

    %{
      position: position,
      team: team_of(position),
      kind: seat.occupant_type,
      name: name,
      initial: name |> String.first() |> to_string() |> String.upcase(),
      avatar_url: avatar_url(seat, bot, profile),
      user_id: seat.user_id,
      quality: connection_quality(seat),
      detail: seat_detail(seat, room, now),
      away: away?(seat),
      turn: live? and summary.current_turn == position,
      dealer: live? and table && table.dealer == position,
      cold: live? and table && position in table.cold,
      bid: if(phase in [:bidding, :declaring] and bid, do: bid),
      bid_key: "#{room.code}-#{summary && summary.hand_number}-#{position}-#{bid}",
      cards_left:
        if(live? and table && phase in [:bidding, :declaring, :discarding, :second_deal, :playing],
          do: min(Map.get(table.cards_left, position, 0), 9)
        )
    }
  end

  defp avatar_url(_seat, bot, _profile) when not is_nil(bot), do: BotCatalogue.avatar_url(bot)
  defp avatar_url(%{occupant_type: :human}, _, profile), do: profile && profile.avatar_url
  defp avatar_url(_, _, _), do: nil

  defp seat_detail(seat, room, now) do
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
      case seat do
        %{occupant_type: :human, status: status} when status in [:reconnecting, :grace] ->
          humanize(status)

        %{status: :bot_substitute} ->
          "Bot sitting in"

        _ ->
          nil
      end
    end
  end

  defp bid_view(room, profiles, {position, amount}) do
    %{
      position: position,
      amount: amount,
      team: team_of(position),
      name: seat_name(room.seats[position], profiles[room.seats[position].user_id])
    }
  end

  defp bid_view(_, _, _), do: nil

  defp center(room, nil, _table, _bid, _seats) do
    cond do
      room.status == :finished -> {:finished, nil}
      room.status == :playing -> {:missing, nil}
      true -> {:waiting, Positions.count(room)}
    end
  end

  defp center(room, summary, table, bid, seats) do
    case summary.phase do
      _ when room.status == :finished ->
        {:finished, winner_names(seats, table)}

      :complete ->
        {:finished, winner_names(seats, table)}

      :bidding ->
        {:bidding, bid}

      :declaring ->
        {:declaring, bid}

      :dealer_selection ->
        {:dealing, "Cutting for deal"}

      phase when phase in [:dealing, :discarding, :second_deal] ->
        {:dealing, if(phase == :dealing, do: "Dealing", else: "Second deal")}

      phase when phase in [:playing, :scoring] ->
        if table && table.trick, do: {:trick, table.trick}, else: {:dealing, "#{leader_name(seats, summary)} leads"}

      :hand_complete ->
        {:hand_done, (table && table.hand_points) || %{north_south: 0, east_west: 0}}

      _ ->
        {:dealing, humanize(summary.phase)}
    end
  end

  defp winner_names(seats, %{winner: team}) when team in [:north_south, :east_west] do
    seats |> Enum.filter(&(&1.team == team)) |> Enum.map_join(" & ", & &1.name)
  end

  defp winner_names(_, _), do: nil

  defp leader_name(seats, %{current_turn: position}) do
    case Enum.find(seats, &(&1.position == position)) do
      nil -> "Next player"
      seat -> seat.name
    end
  end

  defp teams(room, summary, table, seats) do
    scores = (summary && summary.cumulative_scores) || %{}
    playing? = summary && summary.phase in [:playing, :scoring, :hand_complete]
    leader = if map_size(scores) > 0, do: Enum.max_by(scores, &elem(&1, 1)) |> elem(0)
    tied? = map_size(scores) > 0 and scores[:north_south] == scores[:east_west]

    for team <- [:north_south, :east_west] do
      names =
        seats
        |> Enum.filter(&(&1.team == team))
        |> Enum.map(&if(&1.kind == :vacant, do: "Open", else: &1.name))
        |> case do
          ["Open", "Open"] -> "Two open seats"
          pair -> Enum.join(pair, " & ")
        end

      score = if summary, do: Map.get(scores, team, 0), else: "–"
      hand_points = playing? && table && Map.get(table.hand_points, team, 0)

      %{
        key: team,
        names: names,
        score: score,
        progress:
          if(is_integer(score),
            do: Float.round(min(max(score, 0), @winning_score) / @winning_score, 3),
            else: 0
          ),
        hand_points: if(hand_points && hand_points > 0, do: hand_points),
        leading: summary && not tied? && leader == team && room.status != :waiting
      }
    end
  end

  defp trick_pips(%{phase: phase} = summary, table) when phase in [:playing, :scoring] do
    current =
      case table do
        %{trick: %{number: number, winner: nil}} -> number
        _ -> summary.trick_number + 1
      end

    %{current: min(current, @tricks_per_hand), total: @tricks_per_hand}
  end

  defp trick_pips(_, _), do: nil

  defp team_of(position) when position in [:north, :south], do: :north_south
  defp team_of(_), do: :east_west

  # ---------------------------------------------------------------------------
  # Seat preview
  # ---------------------------------------------------------------------------

  defp load_preview(nil, _), do: nil

  defp load_preview(room, position) do
    position = Enum.find(@positions, &(to_string(&1) == position))
    seat = position && room.seats[position]

    cond do
      is_nil(seat) ->
        nil

      seat.occupant_type == :bot ->
        bot = BotCatalogue.profile(seat.bot_persona)

        %{
          code: room.code,
          position: position,
          kind: :bot,
          name: seat_name(seat, nil),
          initial: String.first(seat_name(seat, nil)),
          avatar_url: bot && BotCatalogue.avatar_url(bot),
          strategy: (bot && bot.strategy) || "rulebook",
          description: bot && bot.description,
          connection: if(seat.status == :bot_substitute, do: "Sitting in for an away player")
        }

      seat.occupant_type == :human ->
        human_preview(room, position, seat)

      true ->
        nil
    end
  end

  defp human_preview(room, position, seat) do
    user = if match?({:ok, _}, Ecto.UUID.dump(seat.user_id || "")), do: Auth.get_user(seat.user_id)
    users = if user, do: Auth.get_users_map([user.id]), else: %{}
    badged = users[seat.user_id]
    name = if user, do: User.public_name(user), else: "Unknown player"

    base = %{
      code: room.code,
      position: position,
      kind: :human,
      name: name,
      initial: name |> String.first() |> to_string() |> String.upcase(),
      avatar_url: badged && badged.avatar_url,
      user_id: seat.user_id,
      connection: preview_connection(seat),
      quality: connection_quality(seat),
      registered: not is_nil(user),
      level: "No account",
      title: nil,
      pin: nil,
      guest: false,
      tier: "Unrated",
      games: 0,
      win_rate: "–",
      abandoned: 0,
      joined: nil
    }

    if user do
      stats = Stats.get_user_stats(user.id)

      {level, title, tier} =
        case Profiles.get_profile_for_screen(user.id) do
          {:ok, profile} ->
            {level_label(profile.veteran_level, profile.veteran_prestige), profile.veteran_title,
             skill_label(profile)}

          _ ->
            {"Lvl 1", nil, "Unrated"}
        end

      %{
        base
        | level: level,
          title: title,
          tier: tier,
          registered: true,
          pin: badged && badged.pin,
          guest: user.guest,
          games: stats.games_played,
          win_rate:
            if(stats.games_played > 0, do: "#{round(stats.win_rate * 100)}%", else: "–"),
          abandoned: stats.games_abandoned,
          joined: Calendar.strftime(user.inserted_at, "%b %Y")
      }
    else
      base
    end
  end

  defp skill_label(%{rating_mu: mu, rating_sigma: sigma, rating_games_count: games})
       when is_number(mu) and is_number(sigma) and is_integer(games) do
    case Tier.classify(mu / 1, sigma / 1, games) do
      %{provisional: true} -> "Provisional"
      %{tier: tier} -> tier |> to_string() |> String.capitalize()
    end
  end

  defp skill_label(_profile), do: "Unrated"

  defp connection_quality(%{user_id: user_id, reserved_for: reserved_for} = seat)
       when is_binary(user_id) or is_binary(reserved_for),
       do: Stats.summarize_connections(List.wrap(Seat.connection_totals(seat)))

  defp connection_quality(_seat), do: nil

  defp preview_connection(seat) do
    cond do
      away?(seat) -> "Away since #{Calendar.strftime(seat.disconnected_at, "%H:%M UTC")}"
      seat.status == :connected -> "Connected"
      true -> humanize(seat.status)
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

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

  defp seat_name(%{bot_persona: persona}, _) when is_binary(persona),
    do: Seat.bot_display_name(persona)

  defp seat_name(%{occupant_type: :bot}, _), do: "Bot"
  defp seat_name(_, %{name: name}), do: name
  defp seat_name(%{occupant_type: :vacant}, _), do: "Open seat"
  defp seat_name(_, _), do: "Unknown player"

  defp phase_label(nil, %{status: :finished}), do: "Completed"
  defp phase_label(nil, %{status: :playing}), do: "No process"
  defp phase_label(nil, room), do: humanize(room.status)
  defp phase_label(_, %{status: :finished}), do: "Completed"
  defp phase_label(%{phase: :hand_complete}, _), do: "Hand done"
  defp phase_label(%{phase: :dealer_selection}, _), do: "Dealer selection"
  defp phase_label(%{phase: :declaring}, _), do: "Trump call"
  defp phase_label(%{phase: phase} = summary, _) when phase in [:playing, :scoring] do
    case summary[:table] do
      %{trick: %{number: n, winner: nil}} -> "Trick #{n}"
      _ -> "Trick #{min(summary.trick_number + 1, @tricks_per_hand)}"
    end
  end

  defp phase_label(summary, _), do: humanize(summary.phase)

  defp points(card, trump), do: CardHelpers.point_value(card, trump)

  defp red?({_rank, suit}), do: red?(suit)
  defp red?(suit), do: suit in [:hearts, :diamonds]

  defp seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  defp seconds(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp signed(n) when is_integer(n) and n > 0, do: "+#{n}"
  defp signed(n), do: to_string(n)

  defp humanize(nil), do: ""

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp elapsed(time, now) do
    seconds = max(DateTime.diff(now, time), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

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
