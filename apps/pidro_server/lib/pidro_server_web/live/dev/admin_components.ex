defmodule PidroServerWeb.Dev.AdminComponents do
  @moduledoc false

  use PidroServerWeb, :html

  attr :active, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :flash, :map, required: true
  slot :actions
  slot :inner_block, required: true

  def admin_shell(assigns) do
    ~H"""
    <div class="dev-admin-shell min-h-screen bg-stone-50 text-stone-950">
      <div class="mx-auto max-w-[96rem] px-4 py-4 sm:px-6 lg:px-8">
        <Layouts.flash_group flash={@flash} />
        <.admin_nav active={@active} />
        <p
          :if={warning = Phoenix.Flash.get(@flash, :warning)}
          role="alert"
          class="mb-4 rounded-md border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900"
        >
          {warning}
        </p>
        <header class="mb-4 flex flex-col gap-3 border-b border-stone-200 pb-4 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <div class="flex flex-wrap items-center gap-2 text-xs text-stone-500">
              <span class="rounded-md border border-stone-200 bg-white px-2 py-1 font-medium">
                /admin/{@active}
              </span>
              <span class="rounded-md border border-emerald-200 bg-emerald-50 px-2 py-1 font-medium text-emerald-700">
                Live ops
              </span>
            </div>
            <h1 class="mt-3 text-2xl font-semibold text-stone-950 sm:text-3xl">
              {@title}
            </h1>
            <p :if={@subtitle} class="mt-1 max-w-4xl text-sm leading-6 text-stone-500">
              {@subtitle}
            </p>
          </div>
          <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
            {render_slot(@actions)}
          </div>
        </header>
        <div class="space-y-4">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr :active, :string, required: true

  def admin_nav(assigns) do
    ~H"""
    <div class="mb-4 overflow-hidden rounded-lg border border-stone-200 bg-white">
      <div class="flex flex-col gap-0 lg:flex-row lg:items-stretch lg:justify-between">
        <div class="flex items-center gap-3 border-b border-stone-200 px-3 py-2.5 lg:border-b-0 lg:border-r">
          <div class="grid size-8 place-items-center rounded-md border border-stone-200 bg-stone-950 text-sm font-semibold text-white">
            P
          </div>
          <div>
            <p class="text-sm font-semibold text-stone-950">
              Pidro Ops
            </p>
            <p class="text-xs text-stone-500">
              Game server console
            </p>
          </div>
        </div>
        <nav
          class="flex min-w-0 flex-1 flex-wrap items-center gap-1 p-1.5 text-sm font-medium"
          aria-label="Development admin"
        >
          <.link navigate={~p"/admin/games"} class={nav_item_class(@active == "games")}>
            <.icon name="hero-rectangle-stack" class="size-4" /> Games
          </.link>
          <.link
            navigate={~p"/admin/game-settings"}
            class={nav_item_class(@active == "game-settings")}
          >
            <.icon name="hero-adjustments-horizontal" class="size-4" /> Game Settings
          </.link>
          <.link navigate={~p"/admin/users"} class={nav_item_class(@active == "players")}>
            <.icon name="hero-user-group" class="size-4" /> Players
          </.link>
          <.link navigate={~p"/admin/history"} class={nav_item_class(@active == "history")}>
            <.icon name="hero-clock" class="size-4" /> History
          </.link>
          <.link navigate={~p"/admin/emails"} class={nav_item_class(@active == "emails")}>
            <.icon name="hero-envelope" class="size-4" /> Email
          </.link>
          <.link navigate={~p"/admin/analytics"} class={nav_item_class(@active == "analytics")}>
            <.icon name="hero-chart-bar-square" class="size-4" /> Analytics
          </.link>
          <.link navigate={~p"/admin/beta"} class={nav_item_class(@active == "beta")}>
            <.icon name="hero-chart-pie" class="size-4" /> Beta
          </.link>
          <.link navigate={~p"/admin/admins"} class={nav_item_class(@active == "admins")}>
            <.icon name="hero-lock-closed" class="size-4" /> Admins
          </.link>
          <.link navigate={~p"/admin/bots"} class={nav_item_class(@active == "bots")}>
            <.icon name="hero-cpu-chip" class="size-4" /> Bots
          </.link>
        </nav>
        <div class="flex items-center gap-3 border-t border-stone-200 px-3 py-2 text-xs text-stone-500 lg:border-l lg:border-t-0 lg:py-0">
          <span>Individual admin access</span>
          <.link
            href={~p"/admin/logout"}
            method="delete"
            class="font-semibold text-stone-700 underline"
          >
            Sign out
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :icon, :string, default: "hero-sparkles"
  attr :tone, :string, default: "stone"

  def stat_card(assigns) do
    ~H"""
    <div class={[
      "admin-card-lift rounded-lg border bg-white p-4",
      stat_tone_class(@tone)
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div>
          <dt class="text-xs font-medium text-stone-500">
            {@label}
          </dt>
          <dd class="mt-1 text-2xl font-semibold text-stone-950">{@value}</dd>
          <p :if={@hint} class="mt-1 text-xs leading-5 text-stone-500">{@hint}</p>
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
  attr :body, :string, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="rounded-lg border border-dashed border-stone-200 bg-stone-50/70 px-5 py-8 text-center">
      <div class="mx-auto flex size-10 items-center justify-center rounded-md border border-stone-200 bg-white text-stone-500">
        <.icon name={@icon} class="size-5" />
      </div>
      <h3 class="mt-3 text-sm font-semibold text-stone-950">{@title}</h3>
      <p class="mx-auto mt-2 max-w-md text-sm leading-6 text-stone-500">{@body}</p>
    </div>
    """
  end

  defp nav_item_class(true) do
    "inline-flex items-center gap-2 rounded-md bg-stone-100 px-3 py-2 text-stone-950 transition active:translate-y-px"
  end

  defp nav_item_class(false) do
    "inline-flex items-center gap-2 rounded-md px-3 py-2 text-stone-600 transition hover:bg-stone-100 hover:text-stone-950 active:translate-y-px"
  end

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
