defmodule PidroServerWeb.Dev.UserDetailLive do
  @moduledoc """
  Admin profile view for one player account.
  """

  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Accounts.Auth
  alias PidroServer.Games.Room.Positions
  alias PidroServer.Games.Room.Seat
  alias PidroServer.Games.RoomManager
  alias PidroServer.Profiles
  alias PidroServer.Rating.Tier
  alias PidroServer.Stats

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    end

    case Auth.get_user(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Player account not found.")
         |> push_navigate(to: ~p"/admin/users")}

      user ->
        {:ok,
         socket
         |> assign(:page_title, "#{user.username} · Players")
         |> assign(:user, user)
         |> assign(:show_delete_modal, false)
         |> assign_form(Auth.change_user(user))
         |> load_user_context()}
    end
  end

  @impl true
  def handle_info({:lobby_update, _available_rooms}, socket),
    do: {:noreply, load_user_context(socket)}

  def handle_info({:room_created, _room}, socket), do: {:noreply, load_user_context(socket)}
  def handle_info({:room_updated, _room}, socket), do: {:noreply, load_user_context(socket)}
  def handle_info({:room_closed, _code}, socket), do: {:noreply, load_user_context(socket)}
  def handle_info({:online_count_updated, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.user
      |> Auth.change_user(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  @impl true
  def handle_event("save", %{"user" => params}, socket) do
    case Auth.update_user(socket.assigns.user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:user, user)
         |> assign(:page_title, "#{user.username} · Players")
         |> assign_form(Auth.change_user(user))
         |> load_user_context()
         |> put_flash(:info, "Player saved. Profile card is up to date.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign_form(Map.put(changeset, :action, :validate))
         |> put_flash(:error, "Fix the highlighted fields and save again.")}
    end
  end

  @impl true
  def handle_event("request_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, true)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    user = socket.assigns.user

    case Auth.delete_user(user) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Deleted #{user.username}. Completed game stats still keep the player id."
         )
         |> push_navigate(to: ~p"/admin/users")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> put_flash(:error, "Could not delete #{user.username}. Try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="players"
      title={@user.username}
      subtitle={"Player profile, live table presence, completed game history, and account controls for #{short_id(@user.id)}."}
      flash={@flash}
    >
      <:actions>
        <.link navigate={~p"/admin/history?#{%{user_id: @user.id}}"} class="text-sm underline">
          Archived games
        </.link>
        <.link navigate={~p"/admin/reports?#{%{user_id: @user.id}}"} class="text-sm underline">
          Incident reports
        </.link>
        <.link
          navigate={~p"/admin/users"}
          class="inline-flex items-center gap-2 rounded-sm border border-stone-300 bg-white px-3 py-2 text-sm font-bold text-stone-700 shadow-sm hover:border-orange-300 hover:text-stone-950"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Back to players
        </.link>
      </:actions>

      <section class="overflow-hidden rounded-md border border-stone-300 bg-white shadow-sm">
        <div class="grid gap-4 p-4 lg:grid-cols-[minmax(0,1fr)_24rem] lg:items-center">
          <div class="flex flex-col gap-5 sm:flex-row sm:items-center">
            <div class="flex size-14 shrink-0 items-center justify-center rounded-sm bg-stone-950 text-xl font-black text-white shadow-sm">
              {initials(@user.username)}
            </div>
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <span class={account_badge_class(@user)}>{account_label(@user)}</span>
                <span class="rounded-md bg-stone-100 px-2 py-1 font-mono text-xs text-stone-500">
                  {short_id(@user.id)}
                </span>
              </div>
              <p class="mt-2 text-sm leading-6 text-stone-600">
                Joined {format_datetime_full(@user.inserted_at)} · Last updated {format_datetime_full(
                  @user.updated_at
                )}
              </p>
            </div>
          </div>
          <div class="rounded-md border border-stone-800 bg-stone-950 p-4 text-white">
            <p class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.18em] text-orange-200">
              Player id
            </p>
            <p class="mt-2 break-all font-mono text-xs leading-5 text-stone-100">{@user.id}</p>
          </div>
        </div>
      </section>

      <dl class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.stat_card
          label="Games played"
          value={@stats.games_played}
          hint="Completed games in stored stats"
          icon="hero-rectangle-stack"
          tone="orange"
        />
        <.stat_card
          label="Wins"
          value={@stats.wins}
          hint={"#{@stats.losses} losses"}
          icon="hero-trophy"
          tone="green"
        />
        <.stat_card
          label="Win rate"
          value={format_percent(@stats.win_rate)}
          hint="Based on completed games"
          icon="hero-chart-pie"
          tone="blue"
        />
        <.stat_card
          label="Abandons"
          value={@stats.games_abandoned}
          hint={abandonment_hint(@stats)}
          icon="hero-arrow-right-on-rectangle"
          tone={if @stats.games_abandoned > 0, do: "red", else: "stone"}
        />
      </dl>

      <section class="rounded-md border border-stone-300 bg-white shadow-sm">
        <div class="border-b border-stone-200 px-4 py-3">
          <h2 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
            Progression
          </h2>
          <p class="mt-1 text-xs text-stone-500">
            Veteran level, skill tier, playstyle, mastery, and heritage for this player.
          </p>
        </div>

        <div class="grid gap-4 p-4 lg:grid-cols-2">
          <div class="rounded-lg border border-stone-200 bg-stone-50/70 p-4">
            <div class="flex items-center justify-between gap-2">
              <p class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
                Veteran
              </p>
              <span class="rounded-md bg-stone-950 px-2 py-1 text-xs font-black text-white">
                {level_label(@profile.veteran_level, @profile.veteran_prestige)}
              </span>
            </div>
            <p class="mt-2 text-lg font-black text-stone-950">{@profile.veteran_title}</p>
            <p class="mt-1 text-xs text-stone-500">{@profile.veteran_xp} XP total</p>
            <%= case @profile.veteran_progress do %>
              <% {into, span} -> %>
                <div class="mt-3">
                  <div class="h-2 w-full overflow-hidden rounded-full bg-stone-200">
                    <div
                      class="h-full rounded-full bg-orange-500"
                      style={"width: #{progress_percent(into, span)}%"}
                    >
                    </div>
                  </div>
                  <p class="mt-1 text-xs text-stone-500">
                    {into}/{span} XP to next level
                  </p>
                </div>
              <% :max -> %>
                <p class="mt-3 text-xs font-bold text-emerald-700">Max level reached</p>
            <% end %>
          </div>

          <div class="rounded-lg border border-stone-200 bg-stone-50/70 p-4">
            <p class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Skill
            </p>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <span class="text-lg font-black text-stone-950">{tier_label(@skill.tier)}</span>
              <span
                :if={@skill.provisional}
                class="rounded-md bg-amber-50 px-2 py-1 text-xs font-bold text-amber-700"
              >
                Provisional
              </span>
            </div>
            <p class="mt-3 font-mono text-[0.7rem] leading-5 text-stone-400">
              Internal · μ {format_float(@profile.rating_mu)} · σ {format_float(@profile.rating_sigma)} · {@profile.rating_games_count} rated games
            </p>
          </div>

          <div class="rounded-lg border border-stone-200 bg-stone-50/70 p-4">
            <p class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Playstyle
            </p>
            <%= if @profile.aggression_insufficient do %>
              <p class="mt-2 text-sm font-semibold text-stone-500">
                Not enough data yet
              </p>
              <p class="mt-1 text-xs text-stone-400">
                Bidding tendencies appear once this player has bid in more games.
              </p>
            <% else %>
              <p class="mt-2 text-lg font-black text-stone-950">
                {aggression_label(@profile.aggression_label)}
              </p>
              <p class="mt-1 text-xs text-stone-500">
                Aggression {format_percent(@profile.aggression_needle)} · Avg winning bid {avg_bid_label(
                  @profile.avg_winning_bid
                )}
              </p>
            <% end %>
          </div>

          <div class="rounded-lg border border-stone-200 bg-stone-50/70 p-4">
            <p class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Mastery
            </p>
            <%= if Enum.empty?(@profile.achievements) do %>
              <p class="mt-2 text-sm font-semibold text-stone-500">No achievements earned yet</p>
            <% else %>
              <div class="mt-2 flex flex-wrap gap-2">
                <span
                  :for={achievement <- @profile.achievements}
                  class="rounded-md bg-emerald-50 px-2 py-1 text-xs font-bold text-emerald-700"
                  title={achievement.description}
                >
                  {achievement.name}
                </span>
              </div>
            <% end %>
          </div>

          <div class="rounded-lg border border-stone-200 bg-stone-50/70 p-4 lg:col-span-2">
            <p class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Heritage
            </p>
            <%= if Enum.empty?(@profile.heritage) do %>
              <p class="mt-2 text-sm font-semibold text-stone-500">
                No heritage recognition (not a migrated Pidro 1 player)
              </p>
            <% else %>
              <div class="mt-2 flex flex-wrap gap-2">
                <span
                  :for={badge <- @profile.heritage}
                  class="rounded-md bg-sky-50 px-2 py-1 text-xs font-bold text-sky-700"
                >
                  {heritage_label(badge)}
                </span>
              </div>
            <% end %>
          </div>
        </div>
      </section>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_24rem]">
        <main class="space-y-6">
          <section class="rounded-md border border-stone-300 bg-white shadow-sm">
            <div class="flex flex-col gap-3 border-b border-stone-200 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h2 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
                  Live table presence
                </h2>
                <p class="mt-1 text-xs text-stone-500">
                  Current rooms where this player is seated, reserved, or spectating.
                </p>
              </div>
              <span class="rounded-sm bg-stone-100 px-3 py-2 font-mono text-xs font-bold uppercase tracking-[0.12em] text-stone-700">
                {length(@active_rooms)} live
              </span>
            </div>

            <div class="p-4">
              <%= if Enum.empty?(@active_rooms) do %>
                <.empty_state
                  icon="hero-signal-slash"
                  title="Not at a live table"
                  body="When this player joins, reconnects, or watches a room, it will appear here."
                />
              <% else %>
                <div class="overflow-x-auto">
                  <table class="min-w-full divide-y divide-stone-200">
                    <thead class="bg-stone-50">
                      <tr>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Room
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Role
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Status
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Players
                        </th>
                        <th class="px-4 py-3 text-right text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Open
                        </th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-stone-100">
                      <tr :for={room <- @active_rooms} class="hover:bg-orange-50/50">
                        <td class="px-4 py-3">
                          <div class="font-bold text-stone-950">{room_name(room)}</div>
                          <div class="font-mono text-xs text-stone-400">{room.code}</div>
                        </td>
                        <td class="px-4 py-3 text-sm text-stone-700">
                          {room_role(room, @user.id)}
                        </td>
                        <td class="px-4 py-3">
                          <span class={room_status_class(room.status)}>{room.status}</span>
                        </td>
                        <td class="px-4 py-3 text-sm text-stone-600">
                          {Positions.count(room)} / {room.max_players}
                        </td>
                        <td class="px-4 py-3 text-right text-sm font-semibold">
                          <.link
                            navigate={~p"/admin/games/#{room.code}"}
                            class="inline-flex items-center gap-1 text-orange-700 hover:text-orange-900"
                          >
                            View <.icon name="hero-arrow-up-right" class="size-4" />
                          </.link>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
          </section>

          <section class="rounded-md border border-stone-300 bg-white shadow-sm">
            <div class="border-b border-stone-200 px-4 py-3">
              <h2 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
                Completed games
              </h2>
              <p class="mt-1 text-xs text-stone-500">
                Recent stored game results that include this player.
              </p>
            </div>

            <div class="p-4">
              <%= if Enum.empty?(@recent_games) do %>
                <.empty_state
                  icon="hero-queue-list"
                  title="No completed games recorded"
                  body="Finished games will appear here once the stats table has results for this player."
                />
              <% else %>
                <div class="overflow-x-auto">
                  <table class="min-w-full divide-y divide-stone-200">
                    <thead class="bg-stone-50">
                      <tr>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Game
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Result
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Seat
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Score
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Bid
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                          Duration
                        </th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-stone-100">
                      <tr :for={game <- @recent_games} class="hover:bg-orange-50/50">
                        <% result = Stats.player_result_for(game, @user.id) %>
                        <td class="px-4 py-3">
                          <div class="font-mono text-sm font-bold text-stone-950">
                            {game.room_code}
                          </div>
                          <div class="text-xs text-stone-500">
                            {format_datetime_full(game.completed_at)}
                          </div>
                        </td>
                        <td class="px-4 py-3">
                          <span class={result_badge_class(result)}>
                            {result_label(result)}
                          </span>
                          <div class="mt-1 text-xs text-stone-500">
                            {participation_label(result)}
                          </div>
                        </td>
                        <td class="px-4 py-3 text-sm text-stone-600">
                          {position_label(result)}
                        </td>
                        <td class="px-4 py-3 font-mono text-sm text-stone-700">
                          {game_score(game)}
                        </td>
                        <td class="px-4 py-3 text-sm text-stone-600">
                          {bid_label(game)}
                        </td>
                        <td class="px-4 py-3 text-sm text-stone-600">
                          {format_duration(game.duration_seconds)}
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
          </section>
        </main>

        <aside class="space-y-4">
          <section class="rounded-md border border-stone-300 bg-white p-4 shadow-sm">
            <h2 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
              Edit player
            </h2>
            <p class="mt-1 text-sm leading-6 text-stone-500">
              Update the profile fields the game app uses to identify this player.
            </p>

            <.form
              for={@form}
              id="player-form"
              phx-change="validate"
              phx-submit="save"
              class="mt-5 space-y-4"
            >
              <.input field={@form[:username]} label="Username" required />
              <.input
                field={@form[:email]}
                type="email"
                label="Email"
                placeholder="player@example.com"
              />

              <label class="flex items-start gap-3 rounded-lg border border-stone-200 bg-stone-50 p-3">
                <input type="hidden" name="user[guest]" value="false" />
                <input
                  type="checkbox"
                  name="user[guest]"
                  value="true"
                  checked={checked?(@form[:guest].value)}
                  class="mt-1 rounded border-stone-300 text-orange-600 focus:ring-orange-500"
                />
                <span>
                  <span class="block text-sm font-bold text-stone-950">Guest account</span>
                  <span class="mt-1 block text-xs leading-5 text-stone-500">
                    Use this when the player should be treated as temporary in admin views.
                  </span>
                </span>
              </label>

              <button
                type="submit"
                class="inline-flex w-full items-center justify-center gap-2 rounded-md bg-stone-950 px-4 py-2.5 text-sm font-bold text-white shadow-sm transition hover:-translate-y-0.5 hover:bg-orange-700 active:translate-y-px"
              >
                <.icon name="hero-check" class="size-4" /> Save player
              </button>
            </.form>
          </section>

          <section class="rounded-md border border-stone-300 bg-white p-4 shadow-sm">
            <h2 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
              Abandonment events
            </h2>
            <p class="mt-1 text-sm leading-6 text-stone-500">
              Recorded when reconnect grace expired during a game.
            </p>

            <%= if Enum.empty?(@abandonments) do %>
              <p class="mt-5 rounded-lg bg-emerald-50 px-4 py-3 text-sm font-semibold text-emerald-800">
                No abandonment events recorded.
              </p>
            <% else %>
              <ol class="mt-5 space-y-3">
                <li
                  :for={event <- @abandonments}
                  class="rounded-lg border border-rose-100 bg-rose-50 px-4 py-3"
                >
                  <div class="flex items-center justify-between gap-3">
                    <span class="font-mono text-sm font-bold text-rose-900">
                      {event.room_code}
                    </span>
                    <span class="rounded-md bg-white px-2 py-1 text-xs font-bold text-rose-700">
                      {event.position}
                    </span>
                  </div>
                  <p class="mt-2 text-xs text-rose-700">
                    {format_datetime_full(event.inserted_at)}
                  </p>
                </li>
              </ol>
            <% end %>
          </section>

          <section class="rounded-md border border-rose-200 bg-white p-4 shadow-sm">
            <h2 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-rose-900">
              Danger zone
            </h2>
            <p class="mt-1 text-sm leading-6 text-rose-700">
              Delete the account row. Historical game records keep this player id.
            </p>
            <button
              type="button"
              phx-click="request_delete"
              class="mt-4 inline-flex w-full items-center justify-center gap-2 rounded-md bg-rose-600 px-4 py-2.5 text-sm font-bold text-white shadow-sm transition hover:bg-rose-700 active:translate-y-px"
            >
              <.icon name="hero-trash" class="size-4" /> Delete player
            </button>
          </section>
        </aside>
      </div>

      <%= if @show_delete_modal do %>
        <div class="fixed inset-0 z-50 flex items-end justify-center bg-stone-950/45 p-4 sm:items-center">
          <div class="w-full max-w-lg rounded-lg bg-white p-6 shadow-2xl animate-deal-in">
            <div class="flex gap-4">
              <div class="flex size-11 shrink-0 items-center justify-center rounded-md bg-rose-50 text-rose-700">
                <.icon name="hero-exclamation-triangle" class="size-6" />
              </div>
              <div>
                <h2 class="text-lg font-black text-stone-950">Delete {@user.username}?</h2>
                <p class="mt-2 text-sm leading-6 text-stone-600">
                  This removes the player account from the users table. Completed games and
                  abandonment records keep the raw player id so historical stats remain readable.
                </p>
              </div>
            </div>
            <div class="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
              <button
                type="button"
                phx-click="cancel_delete"
                class="rounded-md border border-stone-300 bg-white px-4 py-2 text-sm font-semibold text-stone-700 shadow-sm hover:bg-stone-50"
              >
                Keep player
              </button>
              <button
                type="button"
                phx-click="confirm_delete"
                class="rounded-md bg-rose-600 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-rose-700 active:translate-y-px"
              >
                Delete player
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </.admin_shell>
    """
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: :user))
  end

  defp load_user_context(socket) do
    user = socket.assigns.user
    {:ok, profile} = Profiles.get_profile_for_screen(user.id)

    socket
    |> assign(:stats, Stats.get_user_stats(user.id))
    |> assign(:profile, profile)
    |> assign(:skill, Tier.classify(profile))
    |> assign(:recent_games, Stats.list_recent_games(player_id: user.id, limit: 20))
    |> assign(:abandonments, Stats.list_user_abandonments(user.id, 8))
    |> assign(:active_rooms, active_rooms_for_user(user.id))
  end

  defp active_rooms_for_user(user_id) do
    case Process.whereis(RoomManager) do
      nil ->
        []

      _pid ->
        RoomManager.list_rooms(:all)
        |> Enum.filter(&room_has_user?(&1, user_id))
    end
  catch
    :exit, _reason -> []
  end

  defp room_has_user?(room, user_id) do
    Positions.has_player?(room, user_id) ||
      user_id in (room.spectator_ids || []) ||
      Seat.reserved_for_user?(room.seats || %{}, user_id)
  end

  defp room_role(room, user_id) do
    cond do
      position = Positions.get_position(room, user_id) ->
        "Seat #{position_label(position)}"

      user_id in (room.spectator_ids || []) ->
        "Spectator"

      Seat.reserved_for_user?(room.seats || %{}, user_id) ->
        "Reconnect reserved"

      true ->
        "Linked"
    end
  end

  defp room_name(room), do: room.config.name || "Game #{room.code}"

  defp room_status_class(:waiting),
    do: "rounded-md bg-amber-50 px-2 py-1 text-xs font-bold text-amber-700"

  defp room_status_class(:ready),
    do: "rounded-md bg-sky-50 px-2 py-1 text-xs font-bold text-sky-700"

  defp room_status_class(:playing),
    do: "rounded-md bg-emerald-50 px-2 py-1 text-xs font-bold text-emerald-700"

  defp room_status_class(:finished),
    do: "rounded-md bg-stone-100 px-2 py-1 text-xs font-bold text-stone-700"

  defp room_status_class(_status),
    do: "rounded-md bg-rose-50 px-2 py-1 text-xs font-bold text-rose-700"

  defp initials(username) when is_binary(username) do
    username
    |> String.trim()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp initials(_username), do: "??"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_id), do: "unknown"

  defp account_label(%{guest: true}), do: "Guest"
  defp account_label(_user), do: "Registered"

  defp account_badge_class(%{guest: true}) do
    "rounded-md bg-sky-50 px-2 py-1 text-xs font-bold text-sky-700"
  end

  defp account_badge_class(_user) do
    "rounded-md bg-emerald-50 px-2 py-1 text-xs font-bold text-emerald-700"
  end

  defp checked?(value), do: Phoenix.HTML.Form.normalize_value("checkbox", value)

  defp abandonment_hint(%{last_abandoned_at: %DateTime{} = datetime}) do
    "Last: #{format_datetime(datetime)}"
  end

  defp abandonment_hint(_stats), do: "Reconnect grace expirations"

  defp result_label(%{result: result}), do: result |> normalize_value() |> String.upcase()
  defp result_label(_result), do: "UNKNOWN"

  defp result_badge_class(%{result: result}) do
    case normalize_value(result) do
      "win" -> "rounded-md bg-emerald-50 px-2 py-1 text-xs font-black text-emerald-700"
      "loss" -> "rounded-md bg-stone-100 px-2 py-1 text-xs font-black text-stone-700"
      _ -> "rounded-md bg-amber-50 px-2 py-1 text-xs font-black text-amber-700"
    end
  end

  defp result_badge_class(_result),
    do: "rounded-md bg-amber-50 px-2 py-1 text-xs font-black text-amber-700"

  defp participation_label(%{participation: participation}) do
    participation
    |> normalize_value()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp participation_label(_result), do: "Participation unknown"

  defp position_label(%{position: position, team: team}) do
    "#{position_label(position)} · #{team_label(team)}"
  end

  defp position_label(:north), do: "North"
  defp position_label(:east), do: "East"
  defp position_label(:south), do: "South"
  defp position_label(:west), do: "West"
  defp position_label("north"), do: "North"
  defp position_label("east"), do: "East"
  defp position_label("south"), do: "South"
  defp position_label("west"), do: "West"
  defp position_label(_position), do: "Seat unknown"

  defp team_label(:north_south), do: "N/S"
  defp team_label(:east_west), do: "E/W"
  defp team_label("north_south"), do: "N/S"
  defp team_label("east_west"), do: "E/W"
  defp team_label(_team), do: "Team unknown"

  defp game_score(%{final_scores: scores}) when is_map(scores) do
    ns = scores[:north_south] || scores["north_south"] || 0
    ew = scores[:east_west] || scores["east_west"] || 0
    "#{ns}-#{ew}"
  end

  defp game_score(_game), do: "0-0"

  defp bid_label(%{bid_amount: amount, bid_team: team}) when is_integer(amount) do
    "#{amount} by #{team_label(team)}"
  end

  defp bid_label(_game), do: "No bid stored"

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 3600 do
    hours = div(seconds, 3600)
    minutes = seconds |> rem(3600) |> div(60)
    "#{hours}h #{minutes}m"
  end

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 60 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp format_duration(seconds) when is_integer(seconds), do: "#{seconds}s"
  defp format_duration(_seconds), do: "Unknown"

  defp format_percent(value) when is_float(value), do: "#{round(value * 100)}%"
  defp format_percent(_value), do: "0%"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp format_datetime(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
  end

  defp format_datetime(_datetime), do: "Unknown"

  defp format_datetime_full(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %H:%M UTC")
  end

  defp format_datetime_full(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime_full()
  end

  defp format_datetime_full(_datetime), do: "Unknown"

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(_value), do: "unknown"

  defp tier_label(tier) when is_atom(tier) do
    tier |> Atom.to_string() |> String.capitalize()
  end

  defp tier_label(_tier), do: "Unknown"

  defp aggression_label(label) when is_atom(label) do
    label |> Atom.to_string() |> String.capitalize()
  end

  defp aggression_label(_label), do: "Unknown"

  defp avg_bid_label(value) when is_number(value), do: format_float(value)
  defp avg_bid_label(_value), do: "—"

  defp progress_percent(_into, span) when span in [nil, 0], do: 0
  defp progress_percent(into, span), do: round(into / span * 100)

  defp format_float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_float(value) when is_integer(value), do: Integer.to_string(value)
  defp format_float(_value), do: "—"

  defp heritage_label(%{label: label, value: true}), do: label
  defp heritage_label(%{label: label, value: value}), do: "#{label}: #{heritage_value(value)}"
  defp heritage_label(_badge), do: "Unknown"

  defp heritage_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp heritage_value(value), do: to_string(value)
end
