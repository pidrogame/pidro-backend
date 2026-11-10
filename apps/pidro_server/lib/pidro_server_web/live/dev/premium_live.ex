defmodule PidroServerWeb.Dev.PremiumLive do
  @moduledoc """
  Who is Premium (PID-397): the numbers by store and source, every `premium`
  row from `PidroServer.Entitlements`, and the claimed Classic subscribers
  who are not Premium here yet. Read once on mount and on each toggle.
  """

  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.{Entitlements, Profiles, RevenueCat}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Premium",
       configured: RevenueCat.configured?(),
       summary: Entitlements.summary(),
       classic: Profiles.classic_subscribers()
     )
     |> load_rows(true)}
  end

  @impl true
  def handle_event("filter", params, socket),
    do: {:noreply, load_rows(socket, params["active_only"] == "true")}

  defp load_rows(socket, active_only),
    do:
      assign(socket, active_only: active_only, rows: Entitlements.list(active_only: active_only))

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell active="premium" title="Premium" flash={@flash}>
      <dl id="premium-summary" class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.stat_card label="Premium now" value={@summary.total} icon="hero-star" tone="orange" />
        <.stat_card
          label="Ending within 7 days"
          value={@summary.expiring_soon}
          icon="hero-clock"
          tone="red"
        />
        <.stat_card
          label="Classic subscribers claimed"
          value={@classic.count}
          hint="Classic Premium still running when they claimed"
          icon="hero-archive-box"
          tone="blue"
        />
        <.stat_card
          label="Of those, not Premium here yet"
          value={length(@classic.not_premium)}
          icon="hero-user-minus"
        />
      </dl>

      <div class="mt-3 flex flex-wrap gap-x-6 gap-y-1 text-sm text-stone-600">
        <p id="premium-by-store">By store: {breakdown(@summary.by_store)}</p>
        <p id="premium-by-source">By source: {breakdown(@summary.by_source)}</p>
      </div>

      <p
        :if={!@configured}
        id="premium-unconfigured"
        class="mt-3 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900"
      >
        RevenueCat is not configured: nobody is Premium until REVENUECAT_SECRET_KEY and REVENUECAT_WEBHOOK_SECRET exist.
      </p>

      <section
        id="premium-rows"
        class="mt-6 overflow-hidden rounded-lg border border-stone-200 bg-white"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-2 border-b border-stone-200 px-4 py-3">
          <h2 class="text-sm font-semibold text-stone-950">Premium</h2>
          <form id="premium-filter" phx-change="filter">
            <input type="hidden" name="active_only" value="false" />
            <label class="inline-flex items-center gap-2 text-sm text-stone-700">
              <input
                type="checkbox"
                name="active_only"
                value="true"
                checked={@active_only}
                class="rounded border-stone-300 text-orange-600 focus:ring-orange-500"
              /> Active only
            </label>
          </form>
        </div>
        <div :if={@rows == []} class="p-4">
          <.empty_state icon="hero-star" title="Nobody is Premium yet." />
        </div>
        <div :if={@rows != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-stone-200 text-sm">
            <thead class="bg-stone-50">
              <tr>
                <th
                  :for={label <- ["Player", "Status", "Ends", "Store", "Source", "Product", "Synced"]}
                  class="px-2 py-2 text-left text-xs font-medium text-stone-600 sm:px-4"
                >
                  {label}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-stone-100">
              <tr :for={row <- @rows} id={"premium-row-#{row.user_id}"}>
                <td class="px-2 py-2 sm:px-4">
                  <.link
                    navigate={user_premium_path(row.user_id)}
                    class="font-semibold text-stone-950 hover:text-orange-700"
                  >
                    {row.name}
                  </.link>
                </td>
                <td class="px-2 py-2 sm:px-4">
                  <span class={[
                    "rounded-md px-2 py-0.5 text-xs font-bold",
                    if(row.active,
                      do: "bg-emerald-50 text-emerald-700",
                      else: "bg-stone-100 text-stone-600"
                    )
                  ]}>
                    {if row.active, do: "Active", else: "Ended"}
                  </span>
                </td>
                <td class="whitespace-nowrap px-2 py-2 tabular-nums text-stone-900 sm:px-4">
                  {if row.expires_at, do: format(row.expires_at), else: "Never (lifetime)"}
                </td>
                <td
                  :for={value <- [row.store, row.source, row.product_id]}
                  class="px-2 py-2 font-mono text-xs text-stone-900 sm:px-4"
                >
                  {value || "unknown"}
                </td>
                <td class="whitespace-nowrap px-2 py-2 tabular-nums text-stone-600 sm:px-4">
                  {if row.last_synced_at, do: format(row.last_synced_at), else: "never"}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section
        id="classic-waiting"
        class="mt-6 overflow-hidden rounded-lg border border-stone-200 bg-white"
      >
        <div class="border-b border-stone-200 px-4 py-3">
          <h2 class="text-sm font-semibold text-stone-950">
            Classic subscribers without Premium here
          </h2>
          <p class="mt-1 text-sm text-stone-600">
            Paying in Classic when they claimed, with no active Premium row here. This is PID-391's work list: carrying their subscription over.
          </p>
        </div>
        <div :if={@classic.not_premium == []} class="p-4">
          <.empty_state
            icon="hero-check-circle"
            title={
              if @classic.count == 0,
                do: "No Classic subscriber has claimed yet.",
                else: "Every Classic subscriber who claimed is Premium here."
            }
          />
        </div>
        <div :if={@classic.not_premium != []} class="overflow-x-auto">
          <table class="min-w-full divide-y divide-stone-200 text-sm">
            <thead class="bg-stone-50">
              <tr>
                <th
                  :for={label <- ["Player", "Classic username", "Classic id", "Claimed"]}
                  class="px-2 py-2 text-left text-xs font-medium text-stone-600 sm:px-4"
                >
                  {label}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-stone-100">
              <tr :for={row <- @classic.not_premium} id={"classic-row-#{row.user_id}"}>
                <td class="px-2 py-2 sm:px-4">
                  <.link
                    navigate={user_premium_path(row.user_id)}
                    class="font-semibold text-stone-950 hover:text-orange-700"
                  >
                    {row.name}
                  </.link>
                </td>
                <td class="px-2 py-2 text-stone-900 sm:px-4">{row.classic_username || "unknown"}</td>
                <td class="px-2 py-2 font-mono text-xs text-stone-600 sm:px-4">
                  {row.classic_user_id}
                </td>
                <td class="whitespace-nowrap px-2 py-2 tabular-nums text-stone-600 sm:px-4">
                  {if row.classic_claimed_at, do: format(row.classic_claimed_at)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </.admin_shell>
    """
  end

  defp user_premium_path(user_id), do: ~p"/admin/users/#{user_id}" <> "#premium"

  defp breakdown(counts) when counts == %{}, do: "none"

  defp breakdown(counts) do
    counts
    |> Enum.sort_by(fn {_key, count} -> -count end)
    |> Enum.map_join(" · ", fn {key, count} -> "#{key || "unknown"} #{count}" end)
  end

  defp format(datetime), do: Calendar.strftime(datetime, "%b %d, %Y %H:%M UTC")
end
