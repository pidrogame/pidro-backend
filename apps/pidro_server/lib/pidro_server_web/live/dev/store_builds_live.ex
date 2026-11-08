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
  def handle_event("refresh", _params, socket) do
    Cache.refresh("android")
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:store_builds, stores}, socket),
    do: {:noreply, socket |> assign(stores: stores) |> load()}

  def handle_info(:tick, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    policy = News.native_update_policy_with_source()
    minimums = StoreBuilds.minimums(policy)
    counts = StoreBuilds.player_versions()

    assign(socket,
      policy: policy,
      minimums: minimums,
      counts: counts,
      now: DateTime.utc_now(),
      steps: StoreBuilds.next_steps(socket.assigns.stores, minimums, counts)
    )
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, step: hd(assigns.steps), more: tl(assigns.steps))

    ~H"""
    <.admin_shell active="store-builds" title="Store builds" flash={@flash}>
      <:actions>
        <p id="checked" class="text-xs text-stone-600 tabular-nums">
          Apple {checked(@stores["ios"].checked_at, @now)} · Google Play {checked(
            @stores["android"].checked_at,
            @now
          )}
        </p>
      </:actions>
      <section
        id="next-steps"
        aria-label="Now"
        class={["rounded-xl border px-5 py-4", tone(@step.tone, :box)]}
      >
        <div class="flex flex-wrap items-center justify-between gap-x-5 gap-y-3.5">
          <div class="flex min-w-0 flex-[1_1_22rem] items-start gap-3.5">
            <span
              aria-hidden="true"
              class={["mt-1.5 size-3 shrink-0 rounded-full", tone(@step.tone, :dot)]}
            ></span>
            <div class="min-w-0 space-y-1">
              <p class="text-lg font-semibold leading-6 text-stone-950">{@step.title}</p>
              <p class="text-sm leading-5 text-stone-700">{@step.text}</p>
            </div>
          </div>
          <.link
            :if={@step.action == :news}
            navigate={~p"/admin/news?app_update=true"}
            class={btn(:dark)}
          >New app-update post</.link>
          <.link
            :if={(@step.action != :news and @step.platform) && @stores[@step.platform].data}
            href={console(@step.platform)}
            target="_blank"
            rel="noopener noreferrer"
            class={btn(if @step.tone == :stuck, do: :dark, else: :light)}
          >{open_console(@step.platform)}</.link>
        </div>
        <ul :if={@more != []} class="mt-3 space-y-1 border-t border-stone-950/10 pt-3 text-sm">
          <li :for={step <- @more} class="text-stone-700">
            {step.text}
            <.link
              :if={step.action == :news}
              navigate={~p"/admin/news?app_update=true"}
              class="font-medium text-stone-950 underline"
            >New app-update post →</.link>
          </li>
        </ul>
      </section>
      <div class="grid gap-4 lg:grid-cols-2">
        <.store_card
          :for={platform <- ~w(ios android)}
          platform={platform}
          store={@stores[platform]}
          minimum={@minimums[platform]}
          counts={@counts}
          now={@now}
        />
      </div>
      <details id="track-details" class="border-t border-stone-200 pt-3">
        <summary class="cursor-pointer text-sm font-medium text-stone-600">Track details</summary>
        <div class="mt-3 grid gap-x-6 gap-y-1.5 text-xs text-stone-700 tabular-nums sm:grid-cols-2 xl:grid-cols-4">
          <span :for={release <- get_in(@stores, ["android", :data, :tracks]) || []}>
            Play {release.track} · {StoreBuilds.build_label(release)} · {StoreBuilds.state_label(
              release.state
            )}
          </span>
          <span :if={newest = get_in(@stores, ["ios", :data, :newest])}>
            TestFlight {if newest.team, do: "Team", else: "newest"} · {StoreBuilds.build_label(newest)} · {StoreBuilds.state_label(
              newest.state
            )}
          </span>
          <span :for={platform <- ~w(ios android)}>
            {StoreBuilds.name(platform)} update notice minimum · {if @minimums[platform],
              do: StoreBuilds.build_label(@minimums[platform]),
              else: "None"} · {@policy.source}
          </span>
          <span :for={platform <- ~w(ios android)} :if={@stores[platform].good_at}>
            {StoreBuilds.store_name(platform)} last good data · {date(@stores[platform].good_at)}
          </span>
        </div>
        <ul class="mt-3 list-disc space-y-1 pl-4 text-xs text-stone-600">
          <li>Apple is checked every 10 minutes; Google Play only when you press Refresh.</li>
          <li>
            Play Refresh uses the EAS submit account: don't refresh while an Android build is being submitted.
          </li>
          <li>
            Play tracks do not report upload, review or release dates. Production drafts do not affect beta players.
          </li>
          <li>
            Versions use Play release names; check that each name matches the binary's native version.
          </li>
          <li>
            Counts are distinct players per platform, version and build, not installs. A player who upgraded can appear under two builds; apps that send no build show the version alone.
          </li>
          <li>Builds not yet uploaded to a store are not visible here.</li>
        </ul>
      </details>
    </.admin_shell>
    """
  end

  attr :platform, :string, required: true
  attr :store, :map, required: true
  attr :minimum, :map, default: nil
  attr :counts, :list, required: true
  attr :now, DateTime, required: true

  defp store_card(assigns) do
    %{platform: platform, store: store, minimum: minimum, counts: counts} = assigns
    live = get_in(store, [:data, :live])

    assigns =
      assign(assigns,
        live: live,
        rail: StoreBuilds.rail(platform, store, minimum, counts, assigns.now),
        players: StoreBuilds.players(platform, store, minimum, counts)
      )

    ~H"""
    <article
      id={"store-#{@platform}"}
      class="flex flex-col gap-5 rounded-xl border border-stone-200 bg-white p-5"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 space-y-0.5">
          <h2 class="text-sm font-semibold text-stone-600">
            {StoreBuilds.name(@platform)} · {if @platform == "ios",
              do: "TestFlight Friends",
              else: "Play open testing"}
          </h2>
          <p class="truncate text-[2.125rem] font-semibold leading-10 tabular-nums [letter-spacing:-0.02em] text-stone-950">
            {cond do
              @live -> @live.version || @live[:label] || "Unknown"
              @store.data -> "None"
              true -> "—"
            end}<span
              :if={@live}
              class="text-[0.9375rem] font-medium [letter-spacing:0] text-stone-600"
            > ({@live.number})</span>
          </p>
          <p :if={!(@store.error && @store.data)} class="text-xs text-stone-600">
            what players can install
          </p>
          <p :if={@store.error && @store.data} class="text-xs text-amber-800">
            last good data · the latest check failed
          </p>
        </div>
        <.link
          href={console(@platform)}
          target="_blank"
          rel="noopener noreferrer"
          aria-label={"Open #{console_name(@platform)}"}
          class={btn(:light)}
        >
          {console_name(@platform)}<.icon name="hero-arrow-up-right" class="size-3" />
        </.link>
      </div>

      <ol
        aria-label={"#{StoreBuilds.name(@platform)} release steps"}
        class="grid grid-cols-4"
      >
        <li :for={{stop, i} <- Enum.with_index(@rail)} class="flex min-w-0 flex-col gap-2">
          <div class="flex items-center">
            <span class={[
              "inline-flex size-[22px] shrink-0 items-center justify-center rounded-full",
              node_class(stop.status)
            ]}>
              <svg
                :if={stop.status == :done}
                class="size-3"
                viewBox="0 0 24 24"
                fill="none"
                stroke="#fff"
                stroke-width="3.5"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              ><path d="m5 12.5 4.5 4.5L19 7.5" /></svg>
              <svg
                :if={stop.status == :stuck}
                class="size-3"
                viewBox="0 0 24 24"
                fill="none"
                stroke="#fff"
                stroke-width="3.5"
                stroke-linecap="round"
                aria-hidden="true"
              ><path d="M12 6v7M12 17.5v.5" /></svg>
            </span>
            <span
              :if={i < 3}
              aria-hidden="true"
              class={[
                "mx-1.5 h-0.5 flex-1",
                if(stop.status == :done, do: "bg-emerald-600", else: "bg-stone-200")
              ]}
            ></span>
          </div>
          <div class="flex min-w-0 flex-col gap-0.5 pr-2">
            <span class="text-[0.6875rem] font-semibold [letter-spacing:.04em] text-stone-600 [text-transform:uppercase]">
              {stop.label}
            </span>
            <span class={[
              "text-sm font-semibold tabular-nums max-sm:text-[0.8125rem]",
              value(stop.status)
            ]}>
              {stop.value}
            </span>
            <span :if={stop.note} class="text-xs tabular-nums text-stone-600">{stop.note}</span>
            <span class="sr-only">{status_text(stop.status)}</span>
          </div>
        </li>
      </ol>

      <div class="space-y-2.5">
        <div class="flex items-baseline justify-between gap-3">
          <p class="text-sm font-semibold text-stone-950">Players this week</p>
          <p class="text-xs tabular-nums text-stone-600">{@players.summary}</p>
        </div>
        <div
          role="img"
          aria-label={"#{StoreBuilds.name(@platform)} players: #{Enum.map_join(@players.segments, ", ", &"#{&1.count} on #{StoreBuilds.build_label(&1)} (#{kind_text(&1.kind)})")}"}
          class="flex h-3 gap-0.5 overflow-hidden rounded-full bg-stone-100"
        >
          <span
            :for={segment <- @players.segments}
            class={["min-w-1", segment_color(segment.kind)]}
            style={"flex: #{segment.count} 1 0"}
          ></span>
        </div>
        <div :if={@players.segments != []} class="flex flex-wrap gap-x-4 gap-y-1.5">
          <span
            :for={segment <- @players.segments}
            class="inline-flex items-center gap-1.5 text-xs tabular-nums text-stone-700"
          >
            <span aria-hidden="true" class={["size-2 rounded-full", segment_color(segment.kind)]}></span>
            <strong class="font-semibold text-stone-950">{StoreBuilds.build_label(segment)}</strong>{segment.count}
          </span>
        </div>
      </div>

      <div
        :if={@platform == "android"}
        class="flex flex-wrap items-center gap-x-3 gap-y-2 border-t border-stone-100 pt-3.5"
      >
        <button
          id="refresh-android"
          type="button"
          phx-click="refresh"
          disabled={@store.refreshing}
          class={[btn(:light), "disabled:opacity-50"]}
        >{if @store.refreshing, do: "Checking…", else: "Refresh"}</button>
        <span class="text-xs text-stone-600">Not while an Android build is being submitted.</span>
      </div>
    </article>
    """
  end

  defp tone(:waiting, :box), do: "border-amber-200 bg-amber-50"
  defp tone(:stuck, :box), do: "border-orange-200 bg-orange-50"
  defp tone(:good, :box), do: "border-emerald-200 bg-emerald-50"
  defp tone(:waiting, :dot), do: "admin-pulse bg-amber-500"
  defp tone(:stuck, :dot), do: "bg-orange-600"
  defp tone(:good, :dot), do: "bg-emerald-600"

  defp node_class(:done), do: "border-2 border-emerald-600 bg-emerald-600"
  defp node_class(:now), do: "admin-pulse border-[6px] border-amber-500 bg-white"
  defp node_class(:stuck), do: "border-2 border-orange-600 bg-orange-600"
  defp node_class(:todo), do: "border-2 border-(--color-stone-300) bg-white"

  defp value(:done), do: "text-stone-950"
  defp value(:now), do: "text-amber-700"
  defp value(:stuck), do: "text-orange-700"
  defp value(:todo), do: "text-stone-500"

  defp status_text(:done), do: "Done"
  defp status_text(:now), do: "Waiting here"
  defp status_text(:stuck), do: "Stuck"
  defp status_text(:todo), do: "Not reached yet"

  defp kind_text(:newest), do: "newest"
  defp kind_text(:nudged), do: "nudged"
  defp kind_text(:older), do: "not nudged"

  defp segment_color(:newest), do: "bg-emerald-600"
  defp segment_color(:nudged), do: "bg-amber-500"
  defp segment_color(:older), do: "bg-stone-400"

  defp btn(:light),
    do:
      "inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-(--color-stone-300) bg-white px-3 text-sm font-medium text-stone-800 hover:bg-stone-100"

  defp btn(:dark),
    do:
      "inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-stone-950 bg-stone-950 px-3 text-sm font-medium text-white hover:bg-stone-700"

  defp console_name("ios"), do: "App Store Connect"
  defp console_name("android"), do: "Play Console"
  defp open_console("ios"), do: "Open TestFlight"
  defp open_console("android"), do: "Open Play Console"

  defp console("ios"), do: "https://appstoreconnect.apple.com/apps/6816832730/testflight/ios"

  defp console("android"),
    do:
      "https://play.google.com/apps/publish/?packageName=com.oneapps.pidro.beta#AppDashboardPlace:p=com.oneapps.pidro.beta"

  defp checked(nil, _), do: "not checked yet"

  defp checked(at, now) do
    case max(div(DateTime.diff(now, at), 60), 0) do
      minutes when minutes < 60 -> "checked #{minutes} min ago"
      minutes -> "checked #{div(minutes, 60)} h ago"
    end
  end

  defp date(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")
end
