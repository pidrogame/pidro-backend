defmodule PidroServerWeb.Dev.BotCatalogueLive do
  @moduledoc "Authenticated catalogue editing; bot identities do not create player accounts."
  use PidroServerWeb, :live_view
  import PidroServerWeb.Dev.AdminComponents
  alias PidroServer.BotCatalogue

  @impl true
  def mount(_params, _session, %{assigns: %{current_admin: nil}} = socket) do
    {:ok, redirect(socket, to: ~p"/admin/login")}
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(PidroServer.PubSub, "bot_catalogue")
    BotCatalogue.refresh()

    {:ok,
     socket
     |> assign(:page_title, "Bots")
     |> assign(:profiles, BotCatalogue.list())
     |> edit(BotCatalogue.new())
     |> allow_upload(:avatar,
       accept: ~w(.png .jpg .jpeg),
       auto_upload: true,
       max_entries: 1,
       max_file_size: 5_242_880
     )}
  end

  @impl true
  def handle_event("new", _params, socket),
    do: {:noreply, socket |> cancel_pending_uploads() |> edit(BotCatalogue.new())}

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, socket |> cancel_pending_uploads() |> edit(BotCatalogue.get!(id))}
  end

  def handle_event(event, %{"bot" => %{"id" => id}}, socket)
      when event in ["validate", "save"] and id != socket.assigns.profile.id do
    {:noreply, put_flash(socket, :error, "Selection changed. Use the current bot form.")}
  end

  def handle_event("validate", %{"bot" => params}, socket) do
    form =
      BotCatalogue.change(socket.assigns.profile, params)
      |> Map.put(:action, :validate)
      |> to_form(as: :bot)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  def handle_event("save", %{"bot" => params}, socket) do
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
      {:ok, profile} ->
        {:noreply,
         socket
         |> edit(profile)
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
    {:noreply, assign(socket, :profiles, BotCatalogue.list())}
  end

  def handle_info(message, socket) do
    PidroServer.Games.UnexpectedMessage.report_once(__MODULE__, message)
    {:noreply, socket}
  end

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
      <div class="grid gap-6 lg:grid-cols-2">
        <section class="min-w-0 rounded-lg border border-stone-200 bg-white p-4 sm:p-6">
          <div class="flex items-center justify-between">
            <h2 class="text-base font-semibold">Catalogue</h2>
            <button
              phx-click="new"
              class="rounded-md bg-stone-950 px-3 py-2 text-sm font-medium text-white hover:bg-stone-800"
            >Add bot</button>
          </div>
          <ul id="bot-list" class="mt-4 divide-y divide-stone-200">
            <li
              :for={profile <- @profiles}
              id={"bot-#{profile.id}"}
              class="flex items-center gap-4 py-4"
            >
              <img
                src={BotCatalogue.avatar_url(profile)}
                alt={profile.name}
                class="size-20 rounded-full"
              />
              <div class="min-w-0 flex-1">
                <h3 class="font-semibold">{profile.name}</h3>
                <p class="break-words text-sm text-stone-600">{profile.description}</p>
                <p class="text-xs text-stone-600">
                  {if profile.enabled, do: "Enabled", else: "Disabled"} · {profile.strategy} · {profile.tempo}
                </p>
              </div>
              <button
                phx-click="edit"
                phx-value-id={profile.id}
                aria-label={"Edit #{profile.name}"}
                class="font-semibold underline"
              >Edit</button>
            </li>
          </ul>
          <p class="mt-4 text-sm text-stone-600">
            If all bots are disabled, games use the original crew. Disabling does not evict a seated bot.
          </p>
        </section>
        <section
          id={"bot-editor-#{@profile.id}"}
          class="min-w-0 rounded-lg border border-stone-200 bg-white p-4 sm:p-6"
        >
          <h2 class="text-base font-semibold">
            {if @profile.__meta__.state == :built, do: "Add bot", else: "Edit #{@profile.name}"}
          </h2>
          <p class="mt-1 break-all text-xs text-stone-600">Stable persona ID: {@profile.id}</p>
          <img
            :if={@profile.name}
            src={BotCatalogue.avatar_url(@profile)}
            alt={@profile.name}
            class="my-4 size-28 rounded-full"
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
                {"Random (existing strategy)", "random"}
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
      </div>
    </.admin_shell>
    """
  end
end
