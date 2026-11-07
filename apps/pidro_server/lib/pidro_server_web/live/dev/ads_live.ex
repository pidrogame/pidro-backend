defmodule PidroServerWeb.Dev.AdsLive do
  @moduledoc """
  The ad schedule (PID-123): its five values, saved in `PidroServer.Settings`
  and read by the next `/me`, and the last 14 days of offers, watches,
  unavailable ads and dismissals from `PidroServer.Ads`.
  """

  use PidroServerWeb, :live_view

  import PidroServerWeb.Dev.AdminComponents

  alias PidroServer.{Ads, Settings}

  @days 14

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Ads") |> load(Settings.change_ads())}
  end

  @impl true
  def handle_event("validate", %{"ads" => params}, socket),
    do:
      {:noreply,
       assign(socket, form: to_form(Settings.change_ads(params), as: :ads, action: :validate))}

  def handle_event("save", %{"ads" => params}, socket) do
    case Settings.put_ads(params) do
      {:ok, _ads} ->
        {:noreply, socket |> load(Settings.change_ads()) |> put_flash(:info, "Ad schedule saved")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :ads))}
    end
  end

  defp load(socket, changeset) do
    ads = Settings.ads()

    assign(socket,
      ads: ads,
      form: to_form(changeset, as: :ads),
      days: Ads.daily_counts(@days),
      past_free_games: Ads.adults_past_free_games(ads)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell active="ads" title="Ads" flash={@flash}>
      <section
        id="ads-switch"
        class={[
          "rounded-lg border p-4 text-sm",
          if(@ads.ads_enabled,
            do: "border-emerald-200 bg-emerald-50 text-emerald-900",
            else: "border-amber-200 bg-amber-50 text-amber-900"
          )
        ]}
      >
        <p :if={!@ads.ads_enabled}>
          <span class="font-semibold">Ads are off.</span>
          Nobody is eligible: <code>/me</code>
          says no ad for every player and no solo room is held back. Turn them on once the 3.3.0 build is in the stores.
        </p>
        <p :if={@ads.ads_enabled}>
          <span class="font-semibold">Ads are on.</span>
          Free adults past {@ads.ads_free_games} games see an ad
          before {every(@ads.ads_early_every_n)} solo game;
          from {@ads.ads_games_until_steady} solo games,
          before {every(@ads.ads_steady_every_n)} solo game.
          Changes apply on the next <code>/me</code>.
        </p>
      </section>

      <section class="mt-6 rounded-lg border border-stone-200 bg-white p-4 sm:p-6">
        <h2 class="text-base font-semibold text-stone-950">Schedule</h2>
        <p class="mt-1 text-sm text-stone-600">
          Solo games only, never at a table with people. Premium players, players under 18 and players with an unknown age never see one.
        </p>
        <.form for={@form} id="ads-form" phx-change="validate" phx-submit="save" class="mt-4">
          <.input field={@form[:ads_enabled]} type="checkbox" label="Ads on (the kill switch)" />
          <div class="grid grid-cols-1 gap-x-6 sm:grid-cols-2 xl:grid-cols-4">
            <.input
              field={@form[:ads_free_games]}
              type="number"
              min="0"
              label="Free games before ads"
            />
            <.input
              field={@form[:ads_early_every_n]}
              type="number"
              min="1"
              label="Then an ad every nth solo game"
            />
            <.input
              field={@form[:ads_games_until_steady]}
              type="number"
              min="0"
              label="Solo games until steady"
            />
            <.input
              field={@form[:ads_steady_every_n]}
              type="number"
              min="1"
              label="Steady: every nth solo game"
            />
          </div>
          <p class="text-xs text-stone-600">
            Free games count games finished in this app, bot games included; Classic games never count. Solo games count every solo game started.
          </p>
          <button
            type="submit"
            class="mt-4 rounded-md bg-stone-950 px-3 py-2 text-sm font-medium text-white hover:bg-stone-800"
          >
            Save
          </button>
        </.form>
      </section>

      <section class="mt-6 overflow-hidden rounded-lg border border-stone-200 bg-white">
        <div class="flex flex-wrap items-baseline justify-between gap-2 border-b border-stone-200 px-4 py-3">
          <h2 class="text-sm font-semibold text-stone-950">Last {length(@days)} days, UTC</h2>
          <p id="ads-past-free-games" class="text-sm text-stone-600">
            Free adults past the free games:
            <span class="font-mono font-semibold tabular-nums text-stone-950">
              {@past_free_games}
            </span>
          </p>
        </div>
        <div class="overflow-x-auto">
          <table id="ads-days" class="min-w-full divide-y divide-stone-200 text-sm">
            <thead class="bg-stone-50">
              <tr>
                <th class="px-2 py-2 text-left text-xs sm:px-4 font-medium text-stone-600">Day</th>
                <th
                  :for={label <- ~w(Offered Watched Unavailable Dismissed)}
                  class="px-2 py-2 text-right text-xs sm:px-4 font-medium text-stone-600"
                >
                  {label}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-stone-100">
              <tr :for={day <- @days} id={"ads-day-#{day.date}"}>
                <td class="whitespace-nowrap px-2 py-2 text-stone-900 sm:px-4">
                  <span class="max-sm:hidden">{Calendar.strftime(day.date, "%a")}</span>
                  {Calendar.strftime(day.date, "%-d %b")}
                </td>
                <td
                  :for={kind <- [:offered, :watched, :unavailable, :dismissed]}
                  class={[
                    "px-2 py-2 text-right font-mono tabular-nums sm:px-4",
                    if(day[kind] == 0, do: "text-stone-400", else: "text-stone-900")
                  ]}
                >
                  {day[kind]}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </.admin_shell>
    """
  end

  defp every(1), do: "every"
  defp every(n) when rem(n, 100) in 11..13, do: "every #{n}th"
  defp every(n) when rem(n, 10) == 1, do: "every #{n}st"
  defp every(n) when rem(n, 10) == 2, do: "every #{n}nd"
  defp every(n) when rem(n, 10) == 3, do: "every #{n}rd"
  defp every(n), do: "every #{n}th"
end
