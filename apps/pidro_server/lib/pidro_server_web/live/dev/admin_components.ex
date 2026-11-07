defmodule PidroServerWeb.Dev.AdminComponents do
  @moduledoc false

  use PidroServerWeb, :html

  @doc """
  Reloads an admin page that mounts with the CSS and JS of an earlier
  release, as a tab left open across a deploy does on its next navigation or
  reconnect. Only production keeps a static manifest to compare against.
  """
  def on_mount(:reload_on_new_assets, _params, _session, socket) do
    if Phoenix.LiveView.static_changed?(socket) do
      {:cont, Phoenix.LiveView.attach_hook(socket, :reload, :handle_params, &reload/3)}
    else
      {:cont, socket}
    end
  end

  defp reload(_params, uri, socket), do: {:halt, Phoenix.LiveView.redirect(socket, external: uri)}

  attr :seats, :map, required: true

  def participant_teams(assigns) do
    ~H"""
    <div class="match-teams">
      <section
        :for={
          {team, positions} <- [{"North / South", [:north, :south]}, {"East / West", [:east, :west]}]
        }
        class="match-team"
      >
        <h3 class="match-team-label">{team}</h3>
        <ul>
          <li :for={position <- positions} class="match-person">
            <% seat = @seats[position] %>
            <span class={["match-avatar", "match-avatar-#{seat.kind}"]} aria-hidden="true">
              <.icon :if={seat.kind == :bot} name="hero-cpu-chip" class="size-4" />
              <.icon :if={seat.kind == :vacant} name="hero-user-plus" class="size-4" />
              <span :if={seat.kind == :human}>{String.first(seat.name)}</span>
              <img
                :if={seat.avatar_url}
                src={seat.avatar_url}
                alt=""
                loading="lazy"
                onerror="this.hidden=true"
              />
            </span>
            <div class="min-w-0">
              <p class="match-person-name">
                <span
                  :if={seat[:quality]}
                  class={[
                    "inline-block size-2 rounded-full mr-1",
                    connection_color(seat.quality.grade)
                  ]}
                  title={"#{connection_label(seat.quality)} · #{seat.quality.checks_sent} checks, #{seat.quality.unanswered_checks} unanswered · #{round(seat.quality.disconnected_seconds)} s disconnected"}
                  aria-label={"Connection: #{connection_label(seat.quality)}"}
                ></span>
                {seat.name}
              </p>
              <p class="match-person-detail">
                {position |> to_string() |> String.capitalize()}{if seat.detail != "",
                  do: " · #{seat.detail}"}
              </p>
            </div>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  def connection_color(grade) do
    %{
      good: "bg-emerald-500",
      fair: "bg-amber-500",
      poor: "bg-red-500",
      insufficient: "bg-stone-300"
    }[grade]
  end

  def connection_label(quality) do
    grade =
      if quality.grade == :insufficient, do: "not enough data", else: to_string(quality.grade)

    latency =
      if quality.median_ms,
        do: "typically #{round(quality.median_ms)} ms, slow (p95) #{round(quality.p95_ms)} ms",
        else: "RTT unknown"

    "#{grade}: #{latency} · #{Float.round(quality.drops_per_hour / 1, 1)} drops per hour of play"
  end

  attr :status, :any, required: true

  def match_status(assigns) do
    {label, icon, tone} =
      case to_string(assigns.status) do
        "playing" ->
          {"In progress", "hero-play-circle", "live"}

        "active" ->
          {"Live / unclosed", "hero-play-circle", "live"}

        status when status in ["complete", "finished"] ->
          {"Completed", "hero-check-circle", "complete"}

        "interrupted" ->
          {"Interrupted", "hero-exclamation-triangle", "warning"}

        "closed" ->
          {"Abandoned / closed", "hero-stop-circle", "neutral"}

        "ready" ->
          {"Ready", "hero-check", "live"}

        "waiting" ->
          {"Waiting", "hero-clock", "neutral"}

        status ->
          {status, "hero-information-circle", "neutral"}
      end

    assigns = assign(assigns, label: label, icon: icon, tone: tone)

    ~H"""
    <span class={["match-status", "match-status-#{@tone}"]}>
      <.icon name={@icon} class="size-4 shrink-0" />{@label}
    </span>
    """
  end

  attr :active, :string, required: true
  attr :title, :string, required: true
  attr :class, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :flash, :map, required: true
  slot :actions
  slot :inner_block, required: true

  def admin_shell(assigns) do
    assigns = assign(assigns, :current, nav_label(assigns.active) || assigns.title)

    ~H"""
    <div class={["dev-admin-shell min-h-screen bg-stone-50 text-stone-950 lg:flex", @class]}>
      <.admin_nav active={@active} current={@current} />
      <main id="admin-main" class="min-w-0 flex-1 px-4 py-6 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-[96rem]">
          <Layouts.flash_group flash={@flash} />
          <p
            :if={warning = Phoenix.Flash.get(@flash, :warning)}
            role="alert"
            class="mb-6 rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900"
          >
            {warning}
          </p>
          <header class={[
            "mb-6 flex flex-wrap items-start justify-between gap-x-6 gap-y-3",
            @title == @current && !@subtitle && @actions == [] && "max-lg:mb-0"
          ]}>
            <div class="min-w-0">
              <h1 class={[
                "text-2xl font-semibold text-stone-950",
                @title == @current && "max-lg:sr-only"
              ]}>
                {@title}
              </h1>
              <p :if={@subtitle} class="mt-1 max-w-3xl text-sm text-stone-600">{@subtitle}</p>
            </div>
            <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
              {render_slot(@actions)}
            </div>
          </header>
          <div class="space-y-6">
            {render_slot(@inner_block)}
          </div>
        </div>
      </main>
    </div>
    """
  end

  attr :active, :string, required: true
  attr :current, :string, required: true

  def admin_nav(assigns) do
    assigns =
      assign(assigns, groups: nav_groups(), attention: PidroServer.StoreBuilds.attention?())

    ~H"""
    <header
      id="admin-topbar"
      class="sticky top-0 z-30 flex h-14 items-center gap-3 border-b border-stone-200 bg-white px-4 lg:hidden"
    >
      <.brand_mark />
      <p class="min-w-0 truncate text-sm">
        <span class="font-semibold">Pidro Ops</span>
        <span class="text-stone-600" aria-hidden="true">/</span>
        <span class="text-stone-600">{@current}</span>
      </p>
      <button
        id="admin-menu-button"
        type="button"
        class="ml-auto grid size-10 place-items-center rounded-md text-stone-700 hover:bg-stone-100"
        aria-label="Open menu"
        aria-controls="admin-sidebar"
        aria-expanded="false"
        phx-click={open_menu()}
      >
        <.icon name="hero-bars-3" class="size-5" />
      </button>
    </header>
    <div
      id="admin-sidebar"
      class="max-lg:hidden max-lg:fixed max-lg:inset-0 max-lg:z-40 lg:sticky lg:top-0 lg:h-screen lg:w-56 lg:shrink-0"
      phx-window-keydown={close_menu()}
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-stone-950/40 lg:hidden" phx-click={close_menu()}></div>
      <div class="relative flex h-full w-72 max-w-[85vw] flex-col border-r border-stone-200 bg-white lg:w-full">
        <div class="flex h-14 shrink-0 items-center gap-3 px-4">
          <.brand_mark />
          <p class="text-sm font-semibold">Pidro Ops</p>
          <button
            type="button"
            class="ml-auto grid size-10 place-items-center rounded-md text-stone-700 hover:bg-stone-100 lg:hidden"
            aria-label="Close menu"
            phx-click={close_menu()}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <nav class="flex-1 space-y-4 overflow-y-auto px-2 py-2" aria-label="Development admin">
          <section :for={{group, links} <- @groups}>
            <p id={"admin-nav-#{group}"} class="px-2 pb-1 text-xs font-medium text-stone-600">
              {group}
            </p>
            <ul class="space-y-px" aria-labelledby={"admin-nav-#{group}"}>
              <li :for={{key, label, path, icon} <- links}>
                <.link
                  navigate={path}
                  aria-current={key == @active && "page"}
                  class={[
                    "flex items-center gap-2.5 rounded-md px-2 py-1.5 text-sm transition-colors max-lg:py-2.5",
                    if(key == @active,
                      do: "bg-stone-950 font-medium text-white",
                      else: "text-stone-700 hover:bg-stone-100 hover:text-stone-950"
                    )
                  ]}
                >
                  <.icon name={icon} class="size-4 shrink-0" />{label}
                  <span
                    :if={key == "store-builds" and @attention}
                    id="store-builds-attention"
                    class="ml-auto size-1.5 rounded-full bg-amber-500"
                  ><span class="sr-only">needs attention</span></span>
                </.link>
              </li>
            </ul>
          </section>
        </nav>
        <div class="shrink-0 border-t border-stone-200 p-2">
          <.link
            href={~p"/admin/logout"}
            method="delete"
            class="flex items-center gap-2.5 rounded-md px-2 py-1.5 text-sm text-stone-700 hover:bg-stone-100 hover:text-stone-950"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4 shrink-0" />Log out
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp brand_mark(assigns) do
    ~H"""
    <span class="grid size-7 shrink-0 place-items-center rounded-md bg-stone-950 text-xs font-semibold text-white">
      P
    </span>
    """
  end

  defp open_menu do
    JS.push_focus()
    |> JS.remove_class("max-lg:hidden", to: "#admin-sidebar")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#admin-menu-button")
    |> JS.set_attribute({"inert", ""}, to: "#admin-main, #admin-topbar")
    |> JS.add_class("max-lg:overflow-hidden", to: "body")
    |> JS.focus_first(to: "#admin-sidebar nav")
  end

  defp close_menu do
    JS.add_class("max-lg:hidden", to: "#admin-sidebar")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#admin-menu-button")
    |> JS.remove_attribute("inert", to: "#admin-main, #admin-topbar")
    |> JS.remove_class("max-lg:overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  defp nav_groups do
    [
      {"Live",
       [
         {"dashboard", "Dashboard", ~p"/admin/dashboard", "hero-squares-2x2"},
         {"games", "Games", ~p"/admin/games", "hero-rectangle-stack"},
         {"players", "Players", ~p"/admin/users", "hero-user-group"},
         {"history", "History", ~p"/admin/history", "hero-clock"}
       ]},
      {"Community",
       [
         {"news", "News", ~p"/admin/news", "hero-newspaper"},
         {"feedback", "Feedback", ~p"/admin/feedback", "hero-chat-bubble-left-ellipsis"},
         {"leagues", "Leagues", ~p"/dev/leagues", "hero-trophy"}
       ]},
      {"Releases",
       [
         {"store-builds", "Store builds", ~p"/admin/store-builds", "hero-device-phone-mobile"},
         {"beta", "Beta", ~p"/admin/beta", "hero-chart-pie"},
         {"emails", "Emails", ~p"/admin/emails", "hero-envelope"}
       ]},
      {"Setup",
       [
         {"game-settings", "Game settings", ~p"/admin/game-settings",
          "hero-adjustments-horizontal"},
         {"ads", "Ads", ~p"/admin/ads", "hero-play-circle"},
         {"bots", "Bots", ~p"/admin/bots", "hero-cpu-chip"},
         {"admins", "Admins", ~p"/admin/admins", "hero-lock-closed"}
       ]},
      {"Numbers", [{"analytics", "Analytics", ~p"/admin/analytics", "hero-chart-bar-square"}]}
    ]
  end

  defp nav_label(active) do
    Enum.find_value(nav_groups(), fn {_group, links} ->
      Enum.find_value(links, fn {key, label, _path, _icon} -> key == active && label end)
    end)
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :icon, :string, default: "hero-sparkles"
  attr :tone, :string, default: "stone"

  def stat_card(assigns) do
    ~H"""
    <div class={["rounded-lg border bg-white p-4", stat_tone_class(@tone)]}>
      <div class="flex items-start justify-between gap-3">
        <div>
          <dt class="text-xs font-medium text-stone-600">
            {@label}
          </dt>
          <dd class="mt-1 text-2xl font-semibold tabular-nums text-stone-950">{@value}</dd>
          <p :if={@hint} class="mt-1 text-xs text-stone-600">{@hint}</p>
        </div>
        <div class={["rounded-md p-1.5", stat_icon_class(@tone)]}>
          <.icon name={@icon} class="size-4" />
        </div>
      </div>
    </div>
    """
  end

  attr :icon, :string, default: "hero-magnifying-glass"
  attr :title, :string, required: true
  attr :body, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <div class="flex items-start gap-2 rounded-lg border border-dashed border-stone-300 px-4 py-3 text-sm text-stone-600">
      <.icon name={@icon} class="mt-0.5 size-4 shrink-0 text-stone-600" />
      <div class="flex flex-wrap gap-x-1">
        <h3 class="font-medium text-stone-950">{@title}</h3>
        <p :if={@body}>· {@body}</p>
      </div>
    </div>
    """
  end

  @doc "A player's level as admin screens show it, with Legend stars past level 100."
  def level_label(_level, prestige) when is_integer(prestige) and prestige >= 1,
    do: "Legend ★#{prestige}"

  def level_label(100, _prestige), do: "Lvl 100 · Legend"
  def level_label(level, _prestige), do: "Lvl #{level}"

  defp stat_tone_class("green"), do: "border-stone-200"
  defp stat_tone_class("orange"), do: "border-stone-200"
  defp stat_tone_class("blue"), do: "border-stone-200"
  defp stat_tone_class("red"), do: "border-rose-200"
  defp stat_tone_class(_tone), do: "border-stone-200"

  defp stat_icon_class("green"), do: "bg-emerald-50 text-emerald-600"
  defp stat_icon_class("orange"), do: "bg-amber-50 text-amber-700"
  defp stat_icon_class("blue"), do: "bg-sky-50 text-sky-600"
  defp stat_icon_class("red"), do: "bg-rose-50 text-rose-700"
  defp stat_icon_class(_tone), do: "bg-stone-100 text-stone-700"
end
