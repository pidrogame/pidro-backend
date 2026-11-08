defmodule PidroServerWeb.Dev.BotCatalogueLive do
  @moduledoc "Authenticated catalogue editing; bot identities do not create player accounts."
  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents
  alias PidroServer.{BotCatalogue, GameArchive}
  alias PidroServer.Games.RoomManager

  @homes [{"finland", "Finland"}, {"louisiana", "Louisiana"}, {"anywhere", "Anywhere"}]
  @strategies [
    {"search", "Plays the odds"},
    {"rulebook", "Plays the honest game"},
    {"random", "Random"}
  ]
  # The profile fields the roster filters on, each one pill group.
  @filters [
    {"Home", :home, @homes},
    {"Strategy", :strategy, @strategies},
    {"Voice", :voice,
     [{"cheerful", "Cheerful"}, {"warm", "Warm"}, {"dry", "Dry"}, {"teasing", "Teasing"}]}
  ]

  @impl true
  def mount(_params, _session, %{assigns: %{current_admin: nil}} = socket) do
    {:ok, redirect(socket, to: ~p"/admin/login")}
  end

  def mount(_params, _session, socket) do
    BotCatalogue.refresh()
    if connected?(socket), do: Phoenix.PubSub.subscribe(PidroServer.PubSub, "bot_catalogue")

    {:ok,
     socket
     |> assign(:page_title, "Bots")
     |> assign(:profiles, BotCatalogue.list())
     |> assign(:facts, facts())
     |> assign(profile: nil, form: nil)
     |> allow_upload(:avatar,
       accept: ~w(.png .jpg .jpeg),
       auto_upload: true,
       max_entries: 1,
       max_file_size: 5_242_880
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters =
      Map.new(@filters, fn {_, key, options} -> {key, pick(params[to_string(key)], options)} end)
      |> Map.put(:enabled, params["enabled"] == "1")

    {:noreply, assign(socket, :filters, filters)}
  end

  @impl true
  def handle_event("new", _params, socket),
    do: {:noreply, socket |> cancel_pending_uploads() |> edit(BotCatalogue.new())}

  # A tap on the card being edited keeps the edits in progress.
  def handle_event("edit", %{"id" => id}, %{assigns: %{profile: %{id: id}}} = socket),
    do: {:noreply, socket}

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, socket |> cancel_pending_uploads() |> edit(BotCatalogue.get!(id))}
  end

  def handle_event("close", _params, socket),
    do: {:noreply, socket |> cancel_pending_uploads() |> assign(profile: nil, form: nil)}

  def handle_event(event, %{"bot" => %{"id" => id}}, %{assigns: %{profile: profile}} = socket)
      when event in ["validate", "save"] and (is_nil(profile) or id != profile.id) do
    {:noreply, put_flash(socket, :error, "Selection changed. Use the current bot form.")}
  end

  def handle_event("validate", %{"bot" => params}, socket) do
    form =
      BotCatalogue.change(socket.assigns.profile, split_lines(params))
      |> Map.put(:action, :validate)
      |> to_form(as: :bot)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  def handle_event("save", %{"bot" => params}, socket) do
    params = split_lines(params)

    results =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
        case BotCatalogue.save(
               socket.assigns.profile,
               Map.put(params, "portrait", "upload"),
               %Plug.Upload{path: path}
             ) do
          {:error, %Ecto.Changeset{}} = error -> {:postpone, error}
          result -> {:ok, result}
        end
      end)

    result =
      case results do
        [] -> BotCatalogue.save(socket.assigns.profile, params)
        [result] -> result
      end

    case result do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(profile: nil, form: nil)
         |> assign(:profiles, BotCatalogue.list())
         |> put_flash(
           :info,
           "Bot saved. Strategy applies to newly seated bots; tempo whenever a bot next starts."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :bot))}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Invalid image. Use a PNG or JPEG up to 5 MiB and 16 megapixels."
         )}
    end
  end

  @impl true
  def handle_info(:bot_catalogue_changed, socket) do
    {:noreply, assign(socket, profiles: BotCatalogue.list(), facts: facts())}
  end

  def handle_info(message, socket) do
    PidroServer.Games.UnexpectedMessage.report_once(__MODULE__, message)
    {:noreply, socket}
  end

  # Every card's facts in one pass: live rooms from the room manager, games
  # and wins from the archive, which names a seat's persona only since `since`.
  defp facts do
    seated =
      RoomManager.list_rooms(:all)
      |> Enum.reject(&(&1.status in [:finished, :closed]))
      |> Enum.flat_map(fn room ->
        for({_, %{occupant_type: :bot, bot_persona: p}} <- room.seats, is_binary(p), do: p)
        |> Enum.uniq()
      end)
      |> Enum.frequencies()

    archive = GameArchive.persona_tallies(DateTime.add(DateTime.utc_now(), -7 * 86_400))
    since = archive |> Map.values() |> Enum.map(& &1.since) |> Enum.min(DateTime, fn -> nil end)
    %{seated: seated, archive: archive, since: since}
  end

  defp pick(value, options), do: if(List.keymember?(options, value, 0), do: value)

  defp visible(profiles, filters) do
    Enum.filter(profiles, fn profile ->
      (profile.enabled or not filters.enabled) and
        Enum.all?(@filters, fn {_, key, _} -> filters[key] in [nil, Map.fetch!(profile, key)] end)
    end)
  end

  defp filter_path(filters, key, value) do
    query =
      filters
      |> Map.put(key, value)
      |> Enum.flat_map(fn
        {:enabled, true} -> [enabled: "1"]
        {key, value} when is_binary(value) -> [{key, value}]
        _ -> []
      end)
      |> Enum.sort()

    if query == [], do: ~p"/admin/bots", else: ~p"/admin/bots?#{query}"
  end

  defp meta(profile) do
    Enum.join(
      [
        home_words(profile.home),
        profile.tempo,
        strategy_words(profile.strategy),
        "#{profile.voice}, #{profile.appetite}"
      ],
      " · "
    )
  end

  defp home_words("anywhere"), do: "anywhere"
  defp home_words(home), do: String.capitalize(home)

  defp strategy_words("search"), do: "plays the odds"
  defp strategy_words("rulebook"), do: "plays the honest game"
  defp strategy_words(strategy), do: strategy

  # The textarea holds one line per line.
  defp split_lines(%{"lines" => text} = params) when is_binary(text),
    do: %{params | "lines" => String.split(text, ["\r\n", "\n"])}

  defp split_lines(params), do: params

  defp cancel_pending_uploads(socket) do
    Enum.reduce(
      socket.assigns.uploads.avatar.entries,
      socket,
      &cancel_upload(&2, :avatar, &1.ref)
    )
  end

  defp edit(socket, profile) do
    socket
    |> assign(:profile, profile)
    |> assign(:form, to_form(BotCatalogue.change(profile), as: :bot))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      active="bots"
      title="Bot crew"
      subtitle="Profiles are public. Strategies are private and fixed when a bot takes its seat."
      flash={@flash}
    >
      <:actions>
        <button
          id="add-bot"
          phx-click="new"
          class="rounded-md bg-stone-950 px-3 py-2 text-sm font-medium text-white hover:bg-stone-800"
        >Add bot</button>
      </:actions>
      <.roster_header profiles={@profiles} filters={@filters} />
      <div class="lg:flex lg:items-start lg:gap-6">
        <.editor :if={@profile} profile={@profile} form={@form} uploads={@uploads} />
        <%!-- Columns follow the roster's own width, which the open panel narrows. --%>
        <div class="@container min-w-0 flex-1">
          <div id="bot-roster" class="grid gap-4 @2xl:grid-cols-2 @4xl:grid-cols-3">
            <.bot_card
              :for={profile <- visible(@profiles, @filters)}
              profile={profile}
              facts={@facts}
              open={@profile && @profile.id == profile.id}
            />
          </div>
          <p
            :if={visible(@profiles, @filters) == []}
            class="rounded-lg border border-dashed border-stone-300 p-6 text-sm text-stone-600"
          >
            No character matches these filters.
          </p>
          <p class="mt-6 text-sm text-stone-600">
            If all bots are disabled, games use the original crew. Disabling does not evict a seated bot.
          </p>
        </div>
      </div>
    </.admin_shell>
    """
  end

  attr :profiles, :list, required: true
  attr :filters, :map, required: true

  defp roster_header(assigns) do
    assigns =
      assign(assigns,
        counts: [
          {"Characters", length(assigns.profiles)},
          {"Play the odds", Enum.count(assigns.profiles, &(&1.strategy == "search"))},
          {"Finland", Enum.count(assigns.profiles, &(&1.home == "finland"))},
          {"Louisiana", Enum.count(assigns.profiles, &(&1.home == "louisiana"))},
          {"Anywhere", Enum.count(assigns.profiles, &(&1.home == "anywhere"))},
          {"Disabled", Enum.count(assigns.profiles, &(!&1.enabled))}
        ],
        groups: @filters
      )

    ~H"""
    <section class="rounded-lg border border-stone-200 bg-white p-4 sm:p-6">
      <dl id="bot-counts" class="grid grid-cols-3 gap-x-6 gap-y-4 sm:grid-cols-6">
        <div
          :for={{label, count} <- @counts}
          id={"count-#{label |> String.downcase() |> String.replace(" ", "-")}"}
        >
          <dt class="text-xs font-medium text-stone-600">{label}</dt>
          <dd class="mt-1 text-2xl font-semibold tabular-nums">{count}</dd>
        </div>
      </dl>
      <nav
        id="bot-filters"
        aria-label="Filter characters"
        class="mt-5 flex flex-wrap items-center gap-x-6 gap-y-3 border-t border-stone-200 pt-4"
      >
        <div :for={{label, key, options} <- @groups} class="flex flex-wrap items-center gap-1.5">
          <span class="mr-1 text-xs font-medium text-stone-600">{label}</span>
          <.pill patch={filter_path(@filters, key, nil)} on={is_nil(@filters[key])}>All</.pill>
          <.pill
            :for={{value, text} <- options}
            patch={filter_path(@filters, key, value)}
            on={@filters[key] == value}
          >
            {text}
          </.pill>
        </div>
        <.pill patch={filter_path(@filters, :enabled, !@filters.enabled)} on={@filters.enabled}>
          Enabled only
        </.pill>
      </nav>
    </section>
    """
  end

  attr :patch, :string, required: true
  attr :on, :boolean, required: true
  slot :inner_block, required: true

  defp pill(assigns) do
    ~H"""
    <.link
      patch={@patch}
      aria-current={@on && "true"}
      class={[
        "rounded-full border px-3 py-1 text-sm",
        if(@on,
          do: "border-stone-950 bg-stone-950 text-white",
          else: "border-stone-300 text-stone-700 hover:border-stone-500"
        )
      ]}
    >{render_slot(@inner_block)}</.link>
    """
  end

  attr :profile, :map, required: true
  attr :facts, :map, required: true
  attr :open, :boolean, default: false

  defp bot_card(assigns) do
    tally = assigns.facts.archive[assigns.profile.id] || %{week: 0, all: 0, decided: 0, wins: 0}
    since = assigns.facts.since

    assigns =
      assign(assigns,
        cells: [
          {"Seated now", Map.get(assigns.facts.seated, assigns.profile.id, 0)},
          {"Past 7 days", since && tally.week},
          {if(since, do: "Since #{Calendar.strftime(since, "%-d %b")}", else: "All games"),
           since && tally.all},
          {"Won", if(tally.decided > 0, do: "#{round(100 * tally.wins / tally.decided)}%")}
        ],
        won_of: tally.decided
      )

    ~H"""
    <article
      id={"bot-#{@profile.id}"}
      phx-click="edit"
      phx-value-id={@profile.id}
      class={[
        "@container flex min-w-0 cursor-pointer flex-col rounded-lg border bg-white p-5 hover:border-stone-400",
        if(@open, do: "border-stone-950", else: "border-stone-200"),
        !@profile.enabled && "opacity-60"
      ]}
    >
      <div class="flex items-start gap-4">
        <img
          src={BotCatalogue.avatar_url(@profile)}
          alt={@profile.name}
          class="size-24 shrink-0 rounded-full bg-[#175086] object-cover"
        />
        <div class="min-w-0 flex-1">
          <div class="flex items-start justify-between gap-3">
            <h3 class="break-words text-xl font-semibold leading-tight">{@profile.name}</h3>
            <button
              phx-click="edit"
              phx-value-id={@profile.id}
              aria-label={"Edit #{@profile.name}"}
              class="shrink-0 text-sm font-medium underline"
            >Edit</button>
          </div>
          <p
            :if={!@profile.enabled}
            class="mt-1 inline-block rounded border border-stone-300 px-1.5 text-xs font-medium text-stone-700"
          >
            Disabled
          </p>
          <p class="bot-meta mt-1 text-sm text-stone-600">{meta(@profile)}</p>
        </div>
      </div>
      <ul :if={@profile.lines != []} class="mt-4 flex flex-wrap gap-1.5">
        <li
          :for={line <- @profile.lines}
          class="rounded-full bg-stone-100 px-2.5 py-0.5 text-xs italic text-stone-700"
        >
          {line}
        </li>
      </ul>
      <p :if={@profile.description != ""} class="mt-3 break-words text-sm text-stone-800">
        {@profile.description}
      </p>
      <div class="flex-1"></div>
      <dl class="bot-facts mt-4 grid grid-cols-2 gap-x-4 gap-y-2 border-t border-stone-200 pt-3 @xs:grid-cols-4">
        <div :for={{label, value} <- @cells} class="min-w-0 whitespace-nowrap">
          <dt class="text-xs text-stone-600">{label}</dt>
          <dd :if={value} class="font-semibold tabular-nums">
            {value}<span :if={label == "Won"} class="text-xs font-normal text-stone-600"> of {@won_of}</span>
          </dd>
          <dd :if={!value} class="text-xs text-stone-500">not recorded</dd>
        </div>
      </dl>
    </article>
    """
  end

  attr :profile, :map, required: true
  attr :form, :any, required: true
  attr :uploads, :map, required: true

  defp editor(assigns) do
    ~H"""
    <section
      id={"bot-editor-#{@profile.id}"}
      role="dialog"
      aria-labelledby="bot-editor-title"
      class="min-w-0 overflow-y-auto bg-white p-4 max-lg:fixed max-lg:inset-0 max-lg:z-40 sm:p-6 lg:sticky lg:top-6 lg:order-last lg:max-h-[calc(100vh-3rem)] lg:w-[26rem] lg:shrink-0 lg:rounded-lg lg:border lg:border-stone-200"
    >
      <div class="flex items-start justify-between gap-3">
        <h2 id="bot-editor-title" class="text-base font-semibold">
          {if @profile.__meta__.state == :built, do: "Add bot", else: "Edit #{@profile.name}"}
        </h2>
        <button type="button" phx-click="close" class="text-sm font-medium underline">Close</button>
      </div>
      <p class="mt-1 break-all text-xs text-stone-600">Stable persona ID: {@profile.id}</p>
      <img
        :if={@profile.name}
        src={BotCatalogue.avatar_url(@profile)}
        alt={@profile.name}
        class="my-4 size-24 rounded-full bg-[#175086] object-cover"
      />
      <.form
        for={@form}
        id="bot-form"
        phx-change="validate"
        phx-submit="save"
        class="mt-4 space-y-3"
      >
        <input type="hidden" name="bot[id]" value={@profile.id} />
        <.input field={@form[:name]} label="Name" maxlength="60" required />
        <.input
          field={@form[:description]}
          type="textarea"
          label="Description (public)"
          maxlength="500"
        />
        <.input field={@form[:enabled]} type="checkbox" label="Enabled for new seats" />
        <.input
          field={@form[:strategy]}
          type="select"
          label="Strategy for new seats"
          options={[
            {"Rulebook (production default)", "rulebook"},
            {"Random (existing strategy)", "random"},
            {"Search (plays the odds)", "search"}
          ]}
        />
        <.input
          field={@form[:tempo]}
          type="select"
          label="Tempo"
          options={[
            {"Quick (0.75 × the bot delay)", "quick"},
            {"Steady (the bot delay)", "steady"},
            {"Slow (1.3 × the bot delay)", "slow"}
          ]}
        />
        <.input
          field={@form[:home]}
          type="select"
          label="Home (seated first at its own crowd's tables)"
          options={[
            {"Anywhere", "anywhere"},
            {"Finland (Ostrobothnia)", "finland"},
            {"Louisiana (the bayou)", "louisiana"}
          ]}
        />
        <.input
          field={@form[:voice]}
          type="select"
          label="Voice at the table"
          options={[
            {"Cheerful (the upbeat regular)", "cheerful"},
            {"Warm (the host)", "warm"},
            {"Dry (the laconic one)", "dry"},
            {"Teasing (the trash talker)", "teasing"}
          ]}
        />
        <.input
          field={@form[:appetite]}
          type="select"
          label="Talks"
          options={[
            {"Sparse (rarely)", "sparse"},
            {"Normal", "normal"},
            {"Chatty (often)", "chatty"}
          ]}
        />
        <.input
          field={@form[:lines]}
          type="textarea"
          label="Lines while thinking (one per line, up to 8 of 18 characters)"
          rows="5"
          value={Enum.join(@form[:lines].value || [], "\n")}
        />
        <.input
          field={@form[:portrait]}
          type="select"
          label="Portrait"
          options={
            [{"Marcel", "marcel"}, {"Antti", "antti"}, {"Jocke", "jocke"}] ++
              if(@profile.image_version, do: [{"Uploaded portrait", "upload"}], else: [])
          }
        />
        <label class="block text-sm font-medium">Upload portrait (PNG/JPEG, max 5 MiB)</label>
        <.live_file_input upload={@uploads.avatar} class="block w-full min-w-0 text-sm" />
        <div :for={entry <- @uploads.avatar.entries}>
          <.live_img_preview entry={entry} class="size-20 rounded-full" />
          <p :for={error <- upload_errors(@uploads.avatar, entry)} class="text-sm text-rose-700">
            Upload rejected: {error}
          </p>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            class="text-sm underline"
          >Cancel upload</button>
        </div>
        <button
          disabled={Enum.any?(@uploads.avatar.entries, &(!&1.done?))}
          class="rounded-md bg-stone-950 px-3 py-2 text-sm font-medium text-white hover:bg-stone-800 disabled:opacity-50"
        >Save bot</button>
      </.form>
    </section>
    """
  end
end
