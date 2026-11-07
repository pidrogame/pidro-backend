defmodule PidroServerWeb.Dev.StoreBuildsLive do
  @moduledoc "Where beta builds reach players, and the next release step."
  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents
  alias PidroServer.{News, StoreBuilds}
  alias PidroServer.StoreBuilds.Cache

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Cache.subscribe()
      :timer.send_interval(60_000, :tick)
    end

    {:ok, socket |> assign(page_title: "Store builds", stores: Cache.snapshot()) |> load()}
  end

  @impl true
  def handle_event("refresh", %{"platform" => platform}, socket)
      when platform in ~w(ios android) do
    Cache.refresh(platform)
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:store_builds, stores}, socket),
    do: {:noreply, socket |> assign(stores: stores) |> load()}

  def handle_info(:tick, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    policy = News.native_update_policy_with_source()
    counts = StoreBuilds.player_versions()

    assign(socket,
      policy: policy,
      counts: counts,
      now: DateTime.utc_now(),
      steps: StoreBuilds.next_steps(socket.assigns.stores, policy.minimum_native_versions, counts)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="store-builds"
      title="Store builds"
      subtitle="What reaches beta players, what holds a release back, and what to do next. Apple checks run every 10 minutes; Google Play is checked on request."
      flash={@flash}
    >
      <section id="next-steps" class="rounded-lg border border-stone-200 bg-white p-4 sm:p-6">
        <h2 class="text-base font-semibold">Next steps</h2>
        <ul class="mt-3 space-y-3 text-sm leading-6">
          <li :for={step <- @steps}>
            <p>{step.text}</p>
            <.link
              :if={step.action == :news}
              navigate={~p"/admin/news?app_update=true"}
              class="font-semibold text-stone-800 underline"
            >New app-update post →</.link>
          </li>
        </ul>
      </section>
      <section
        :for={platform <- ~w(ios android)}
        id={"store-#{platform}"}
        class="rounded-lg border border-stone-200 bg-white p-4 sm:p-6"
      >
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h2 class="text-base font-semibold">{StoreBuilds.name(platform)}</h2>
          <.link
            href={console(platform)}
            target="_blank"
            rel="noopener noreferrer"
            class="text-sm text-stone-600 underline"
          >{StoreBuilds.store_name(platform)} ↗</.link>
        </div>
        <p class="mt-1 text-xs text-stone-600">{checked(@stores[platform].checked_at, @now)}</p>
        <button
          id={"refresh-#{platform}"}
          phx-click="refresh"
          phx-value-platform={platform}
          disabled={@stores[platform].refreshing}
          class="mt-3 rounded-md border border-stone-300 bg-white px-3 py-2 text-sm font-medium text-stone-800 hover:bg-stone-100 disabled:opacity-50"
        >{if @stores[platform].refreshing, do: "Checking…", else: "Refresh"}</button>
        <p :if={platform == "android"} class="mt-1 text-xs text-stone-600">
          Uses the EAS submit account: don't refresh while an Android build is being submitted.
        </p>
        <p :if={@stores[platform].error} role="alert" class="mt-3 text-sm text-amber-800">
          {error(platform, @stores[platform].error)}
          <span :if={@stores[platform].good_at}>Last good data: {date(@stores[platform].good_at)}.</span>
        </p>
        <div class="mt-4 grid gap-5 text-sm md:grid-cols-2 xl:grid-cols-4">
          <div>
            <h3 class="text-xs font-medium text-stone-600">
              {if platform == "ios", do: "Newest uploaded build", else: "Newest build in Play tracks"}
            </h3>
            <p class="mt-1 font-semibold">
              {StoreBuilds.build_label(get_in(@stores, [platform, :data, :newest]))}
            </p>
            <p>{StoreBuilds.state_label(get_in(@stores, [platform, :data, :newest, :state]))}</p>
            <p class="mt-1 text-xs text-stone-600">
              {date(get_in(@stores, [platform, :data, :newest, :uploaded_at]))}
            </p>
          </div>
          <div>
            <h3 class="text-xs font-medium text-stone-600">
              Live for players · {if platform == "ios", do: "Friends", else: "Open testing"}
            </h3>
            <p class="mt-1 font-semibold text-emerald-800">
              {StoreBuilds.build_label(get_in(@stores, [platform, :data, :live]))}
            </p>
            <p class="mt-1 text-xs text-stone-600">
              Live since: {date(get_in(@stores, [platform, :data, :live, :since]))}
            </p>
          </div>
          <div>
            <h3 class="text-xs font-medium text-stone-600">Minimum for the update notice</h3>
            <p class="mt-1 font-semibold">{@policy.minimum_native_versions[platform] || "None"}</p>
            <p class="mt-1 text-xs text-stone-600">{@policy.source}</p>
          </div>
          <div>
            <h3 class="text-xs font-medium text-stone-600">Players per version · last 7 days</h3>
            <p :if={!Enum.any?(@counts, &(&1.platform == platform))} class="mt-1 text-stone-600">
              No recorded players
            </p>
            <p
              :for={count <- Enum.filter(@counts, &(&1.platform == platform))}
              class="mt-1 flex justify-between gap-3"
            >
              <span>{count.version}</span><strong>{count.count}</strong>
            </p>
          </div>
        </div>
        <p
          :if={platform == "android"}
          class="mt-4 border-t border-stone-100 pt-3 text-xs text-stone-600"
        >
          Track information:
          <span
            :for={release <- get_in(@stores, [platform, :data, :tracks]) || []}
            class="mr-3 inline-block"
          >{release.track}: {StoreBuilds.build_label(release)} · {StoreBuilds.state_label(
            release.state
          )}</span>
          Play tracks do not report upload or release dates. Production drafts do not affect beta players.
          Versions use Play release names; check that each name matches the binary's native version.
        </p>
      </section>
      <p class="text-xs text-stone-600">
        Counts are distinct players per platform and version, not installs. A player who upgraded can appear under two versions. Builds not yet uploaded to a store are not visible here.
      </p>
    </.admin_shell>
    """
  end

  defp console("ios"), do: "https://appstoreconnect.apple.com/apps/6816832730/testflight/ios"

  defp console("android"),
    do:
      "https://play.google.com/apps/publish/?packageName=com.oneapps.pidro.beta#AppDashboardPlace:p=com.oneapps.pidro.beta"

  defp error(platform, :not_connected), do: "#{StoreBuilds.store_name(platform)} not connected"
  defp error(_, error), do: error
  defp checked(nil, _), do: "Not checked yet"
  defp checked(at, now), do: "Checked #{max(div(DateTime.diff(now, at), 60), 0)} min ago"
  defp date(nil), do: "Not reported by the API"
  defp date(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")
  defp date(value), do: value
end
