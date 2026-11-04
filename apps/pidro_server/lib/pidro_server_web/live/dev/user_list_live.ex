defmodule PidroServerWeb.Dev.UserListLive do
  @moduledoc """
  Admin player directory for inspecting and managing registered Pidro users.
  """

  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.Accounts.Auth
  alias PidroServer.Games.Room.Positions
  alias PidroServer.Games.RoomManager
  alias PidroServer.Profiles
  alias PidroServer.Stats

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PidroServer.PubSub, "lobby:updates")
    end

    {:ok,
     socket
     |> assign(:page_title, "Players")
     |> assign(:filters, default_filters())
     |> assign(:show_delete_modal, false)
     |> assign(:user_to_delete, nil)
     |> load_users()}
  end

  @impl true
  def handle_info({:lobby_update, _available_rooms}, socket), do: {:noreply, load_users(socket)}
  def handle_info({:room_created, _room}, socket), do: {:noreply, load_users(socket)}
  def handle_info({:room_updated, _room}, socket), do: {:noreply, load_users(socket)}
  def handle_info({:room_closed, _code}, socket), do: {:noreply, load_users(socket)}
  def handle_info({:online_count_updated, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter_users", %{"filters" => params}, socket) do
    filters =
      socket.assigns.filters
      |> Map.merge(%{
        search: Map.get(params, "search", ""),
        guest: Map.get(params, "guest", "all"),
        sort: Map.get(params, "sort", "recent"),
        page: 1
      })

    {:noreply, socket |> assign(:filters, filters) |> load_users()}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    filters = %{socket.assigns.filters | page: parse_page(page)}
    {:noreply, socket |> assign(:filters, filters) |> load_users()}
  end

  @impl true
  def handle_event("request_delete", %{"id" => id}, socket) do
    case Auth.get_user(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That player account no longer exists.")}

      user ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, true)
         |> assign(:user_to_delete, user)}
    end
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, close_delete_modal(socket)}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    case socket.assigns.user_to_delete do
      nil ->
        {:noreply, close_delete_modal(socket)}

      user ->
        case Auth.delete_user(user) do
          {:ok, _user} ->
            {:noreply,
             socket
             |> close_delete_modal()
             |> put_flash(
               :info,
               "Deleted #{user.username}. Completed game stats still keep the player id."
             )
             |> load_users()}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> close_delete_modal()
             |> put_flash(:error, "Could not delete #{user.username}. Try again.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="players"
      title="Players"
      subtitle="Search game accounts, inspect history, edit profile fields, and remove accounts while preserving completed match records."
      flash={@flash}
    >
      <:actions>
        <span class="rounded-sm border border-stone-300 bg-white px-3 py-2 font-mono text-xs font-bold uppercase tracking-[0.14em] text-stone-600">
          Registration: game app only
        </span>
      </:actions>

      <dl class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-5">
        <.stat_card
          label="Total players"
          value={@summary.total}
          hint="All accounts in the users table"
          icon="hero-user-group"
          tone="orange"
        />
        <.stat_card
          label="Registered"
          value={@summary.registered}
          hint="Non-guest player accounts"
          icon="hero-user-circle"
          tone="green"
        />
        <.stat_card
          label="Guests"
          value={@summary.guests}
          hint="Temporary or guest accounts"
          icon="hero-face-smile"
          tone="blue"
        />
        <.stat_card
          label="With email"
          value={@summary.with_email}
          hint="Accounts with contact info"
          icon="hero-envelope"
        />
        <.stat_card
          label="Active now"
          value={@summary.active_now}
          hint="Seated or spectating live rooms"
          icon="hero-signal"
          tone="green"
        />
      </dl>

      <section class="rounded-md border border-stone-300 bg-white p-3 shadow-sm">
        <form
          id="user-filters"
          phx-change="filter_users"
          phx-submit="filter_users"
          class="grid gap-3 lg:grid-cols-[minmax(16rem,1fr)_12rem_12rem]"
        >
          <label class="block">
            <span class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Search players
            </span>
            <div class="mt-1 flex items-center rounded-md border border-stone-300 bg-white px-3 shadow-sm transition focus-within:border-orange-500 focus-within:ring-2 focus-within:ring-orange-200">
              <.icon name="hero-magnifying-glass" class="mr-2 size-4 text-stone-400" />
              <input
                type="search"
                name="filters[search]"
                value={@filters.search}
                phx-debounce="250"
                placeholder="Username, email, or player id"
                class="w-full border-0 bg-transparent py-2 text-sm text-stone-950 placeholder:text-stone-400 focus:ring-0"
              />
            </div>
          </label>

          <label class="block">
            <span class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Account type
            </span>
            <select
              name="filters[guest]"
              class="mt-1 w-full rounded-md border-stone-300 bg-white py-2 text-sm shadow-sm focus:border-orange-500 focus:ring-orange-500"
            >
              <option value="all" selected={@filters.guest == "all"}>All players</option>
              <option value="registered" selected={@filters.guest == "registered"}>
                Registered
              </option>
              <option value="guest" selected={@filters.guest == "guest"}>Guests</option>
            </select>
          </label>

          <label class="block">
            <span class="font-mono text-[0.68rem] font-bold uppercase tracking-[0.14em] text-stone-500">
              Sort
            </span>
            <select
              name="filters[sort]"
              class="mt-1 w-full rounded-md border-stone-300 bg-white py-2 text-sm shadow-sm focus:border-orange-500 focus:ring-orange-500"
            >
              <option value="recent" selected={@filters.sort == "recent"}>Newest first</option>
              <option value="updated" selected={@filters.sort == "updated"}>Recently edited</option>
              <option value="username" selected={@filters.sort == "username"}>Username A-Z</option>
              <option value="oldest" selected={@filters.sort == "oldest"}>Oldest first</option>
            </select>
          </label>
        </form>
      </section>

      <section class="overflow-hidden rounded-md border border-stone-300 bg-white shadow-sm">
        <div class="flex flex-col gap-3 border-b border-stone-200 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 class="font-mono text-xs font-black uppercase tracking-[0.16em] text-stone-700">
              Player index
            </h2>
            <p class="mt-1 text-xs text-stone-500">
              Showing {first_result(@page)}-{last_result(@page)} of {@page.total} players
            </p>
          </div>
          <div class="inline-flex items-center gap-2 rounded-sm bg-stone-100 px-3 py-2 font-mono text-xs font-bold uppercase tracking-[0.12em] text-stone-700">
            <.icon name="hero-arrows-up-down" class="size-4" />
            Page {@page.page} of {@page.total_pages}
          </div>
        </div>

        <%= if Enum.empty?(@users) do %>
          <div class="p-5">
            <.empty_state
              title="No players match this view"
              body="Try a different search or switch the account type filter back to all players."
            />
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-stone-200">
              <thead class="bg-stone-50">
                <tr>
                  <th class="px-4 py-2.5 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                    Player
                  </th>
                  <th class="px-4 py-2.5 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                    Email
                  </th>
                  <th class="px-4 py-2.5 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                    Games
                  </th>
                  <th class="px-4 py-2.5 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                    Win rate
                  </th>
                  <th class="px-4 py-2.5 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                    Level
                  </th>
                  <th class="px-4 py-2.5 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                    Skill tier
                  </th>
                  <th class="px-4 py-2.5 text-left text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                    Joined
                  </th>
                  <th class="px-4 py-2.5 text-right text-xs font-bold uppercase tracking-[0.16em] text-stone-500">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-stone-100 bg-white">
                <tr :for={user <- @users} class="transition hover:bg-orange-50/50">
                  <td class="px-4 py-3">
                    <div class="flex items-center gap-3">
                      <div class="flex size-10 shrink-0 items-center justify-center rounded-md bg-stone-950 text-sm font-black text-white shadow-sm">
                        {initials(user.username)}
                      </div>
                      <div>
                        <.link
                          navigate={~p"/admin/users/#{user.id}"}
                          class="font-bold text-stone-950 hover:text-orange-700"
                        >
                          {user.username}
                        </.link>
                        <div class="mt-1 flex flex-wrap items-center gap-2">
                          <span class={account_badge_class(user)}>
                            {account_label(user)}
                          </span>
                          <span class="font-mono text-xs text-stone-400">
                            {short_id(user.id)}
                          </span>
                        </div>
                      </div>
                    </div>
                  </td>
                  <td class="px-4 py-3 text-sm text-stone-600">
                    <%= if present?(user.email) do %>
                      {user.email}
                    <% else %>
                      <span class="text-stone-400">No email</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-sm">
                    <div class="font-bold text-stone-950">
                      {row_stats(@stats_by_user, user.id).games_played}
                    </div>
                    <div class="text-xs text-stone-500">
                      {row_stats(@stats_by_user, user.id).wins} wins · {row_stats(
                        @stats_by_user,
                        user.id
                      ).games_abandoned} abandons
                    </div>
                  </td>
                  <td class="px-4 py-3 text-sm font-semibold text-stone-700">
                    {format_percent(row_stats(@stats_by_user, user.id).win_rate)}
                  </td>
                  <td class="px-4 py-3 text-sm font-semibold text-stone-700">
                    <% summary = row_summary(@summaries_by_user, user.id) %>
                    {level_label(summary.veteran_level, summary.prestige)}
                  </td>
                  <td class="px-4 py-3 text-sm">
                    <% summary = row_summary(@summaries_by_user, user.id) %>
                    <%= if summary.provisional do %>
                      <span class="rounded-md bg-amber-50 px-2 py-1 text-xs font-bold text-amber-700">
                        Provisional
                      </span>
                    <% else %>
                      <span class="font-semibold text-stone-700">{tier_label(summary.tier)}</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-sm text-stone-600">
                    {format_datetime(user.inserted_at)}
                  </td>
                  <td class="px-4 py-3 text-right text-sm font-semibold">
                    <div class="flex justify-end gap-3">
                      <.link
                        navigate={~p"/admin/users/#{user.id}"}
                        class="inline-flex items-center gap-1 text-orange-700 hover:text-orange-900"
                      >
                        <.icon name="hero-eye" class="size-4" /> View
                      </.link>
                      <button
                        type="button"
                        phx-click="request_delete"
                        phx-value-id={user.id}
                        class="inline-flex items-center gap-1 text-rose-600 hover:text-rose-800"
                      >
                        <.icon name="hero-trash" class="size-4" /> Delete
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>

        <div class="flex flex-col gap-3 border-t border-stone-200 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
          <p class="text-sm text-stone-500">
            Completed game stats are preserved even when an account is deleted.
          </p>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="change_page"
              phx-value-page={@page.page - 1}
              disabled={@page.page <= 1}
              class="inline-flex items-center gap-2 rounded-md border border-stone-300 bg-white px-3 py-2 text-sm font-semibold text-stone-700 shadow-sm transition hover:border-orange-300 hover:text-stone-950 disabled:cursor-not-allowed disabled:opacity-40"
            >
              <.icon name="hero-chevron-left" class="size-4" /> Previous
            </button>
            <button
              type="button"
              phx-click="change_page"
              phx-value-page={@page.page + 1}
              disabled={@page.page >= @page.total_pages}
              class="inline-flex items-center gap-2 rounded-md border border-stone-300 bg-white px-3 py-2 text-sm font-semibold text-stone-700 shadow-sm transition hover:border-orange-300 hover:text-stone-950 disabled:cursor-not-allowed disabled:opacity-40"
            >
              Next <.icon name="hero-chevron-right" class="size-4" />
            </button>
          </div>
        </div>
      </section>

      <%= if @show_delete_modal and @user_to_delete do %>
        <div class="fixed inset-0 z-50 flex items-end justify-center bg-stone-950/45 p-4 sm:items-center">
          <div class="w-full max-w-lg rounded-lg bg-white p-6 shadow-2xl animate-deal-in">
            <div class="flex gap-4">
              <div class="flex size-11 shrink-0 items-center justify-center rounded-md bg-rose-50 text-rose-700">
                <.icon name="hero-exclamation-triangle" class="size-6" />
              </div>
              <div>
                <h2 class="text-lg font-black text-stone-950">
                  Delete {@user_to_delete.username}?
                </h2>
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

  defp load_users(socket) do
    page = Auth.list_users(filters_to_opts(socket.assigns.filters))
    users = page.entries
    user_ids = Enum.map(users, & &1.id)
    stats_by_user = Stats.get_user_stats_map(user_ids)
    summaries_by_user = Profiles.summaries_for(user_ids)

    summary =
      Auth.user_admin_summary()
      |> Map.put(:active_now, active_user_count())

    socket
    |> assign(:users, users)
    |> assign(:page, page)
    |> assign(:stats_by_user, stats_by_user)
    |> assign(:summaries_by_user, summaries_by_user)
    |> assign(:summary, summary)
  end

  defp default_filters do
    %{search: "", guest: "all", sort: "recent", page: 1, per_page: @per_page}
  end

  defp filters_to_opts(filters) do
    [
      search: filters.search,
      guest: filters.guest,
      sort: filters.sort,
      page: filters.page,
      per_page: filters.per_page
    ]
  end

  defp close_delete_modal(socket) do
    socket
    |> assign(:show_delete_modal, false)
    |> assign(:user_to_delete, nil)
  end

  defp active_user_count do
    case Process.whereis(RoomManager) do
      nil ->
        0

      _pid ->
        RoomManager.list_rooms(:all)
        |> Enum.flat_map(fn room -> Positions.player_ids(room) ++ (room.spectator_ids || []) end)
        |> MapSet.new()
        |> MapSet.size()
    end
  catch
    :exit, _reason -> 0
  end

  defp row_stats(stats_by_user, user_id) do
    Map.get(stats_by_user, user_id, %{
      games_played: 0,
      wins: 0,
      losses: 0,
      win_rate: 0.0,
      games_abandoned: 0
    })
  end

  defp row_summary(summaries_by_user, user_id) do
    Map.get(summaries_by_user, user_id, %{
      veteran_level: 1,
      prestige: 0,
      tier: :provisional,
      provisional: true
    })
  end

  defp tier_label(tier) when is_atom(tier), do: tier |> Atom.to_string() |> String.capitalize()
  defp tier_label(_tier), do: "Unknown"

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {value, _} when value > 0 -> value
      _ -> 1
    end
  end

  defp parse_page(page) when is_integer(page) and page > 0, do: page
  defp parse_page(_page), do: 1

  defp first_result(%{total: 0}), do: 0
  defp first_result(%{page: page, per_page: per_page}), do: (page - 1) * per_page + 1

  defp last_result(%{total: total, page: page, per_page: per_page}) do
    min(page * per_page, total)
  end

  defp initials(username) when is_binary(username) do
    username
    |> String.trim()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp initials(_username), do: "??"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_id), do: "unknown"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp account_label(%{guest: true}), do: "Guest"
  defp account_label(_user), do: "Registered"

  defp account_badge_class(%{guest: true}) do
    "rounded-md bg-sky-50 px-2 py-1 text-xs font-bold text-sky-700"
  end

  defp account_badge_class(_user) do
    "rounded-md bg-emerald-50 px-2 py-1 text-xs font-bold text-emerald-700"
  end

  defp format_percent(value) when is_float(value), do: "#{round(value * 100)}%"
  defp format_percent(_value), do: "0%"

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp format_datetime(_datetime), do: "Unknown"
end
